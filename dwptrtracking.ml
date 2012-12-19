open Defs

module BS = Ir.IrBS
module CS = Ir.IrCS
module CT = Ir.IrCT
module C = Ir.Ir

(* We can sometimes tell the names and proper types of registers too -- that's
   not handled at present, and probably won't be handled here anyway.  *)

let fb_relative_var_loc loc =
  match loc with
    Dwarfreader.Loc_expr (`DW_OP_fbreg offs) -> offs
  (*| Dwarfreader.Loc_list _ -> failwith "unimplemented"*)
  | _ -> raise Not_found

let known_var vars sp_offset =
  let fv, ofs =
    List.fold_left
      (fun ((found_var, offset) as prev) var ->
	match var.Function.var_location with
          None -> prev
	| Some loc ->
            try
	      let var_offset = fb_relative_var_loc loc in
	      if sp_offset >= var_offset
		 && sp_offset < (var_offset + var.Function.var_size) then begin
		Log.printf 3 "sp offset:%d var_offset:%d var_size:%d\n"
		  sp_offset var_offset var.Function.var_size;
		Some var, sp_offset - var_offset
	      end else
		prev
	    with Not_found -> prev)
      (None, 0)
      vars in
  match fv with
    Some f -> f, ofs
  | None -> raise Not_found

let reg_or_ssareg_probably_pointer regid ct_for_cu inforec vartype_hash =
  match regid with
    C.SSAReg regid -> Typedb.probably_pointer ct_for_cu regid inforec
  | C.Reg reg ->
      begin match vartype_hash with
        Some vh ->
	  let vti = Hashtbl.find vh (Vartypes.T_reg reg) in
	  Ctype.pointer_type ct_for_cu vti.Vartypes.vt_type
      | None -> false
      end
  | _ -> failwith "Not reg or ssa reg"

module IrPhiPlacement = Phi.PhiPlacement (Ir.IrCT) (Ir.IrCS) (Ir.IrBS)

let try_rewrite_access var_reg var_type aggr_access rewrite_as =
  match rewrite_as with
    `load (_, dst) -> (* FIXME: Verify access size!  *)
      C.Set (dst, C.Unary (Irtypes.Aggr_member (var_type, aggr_access),
			   var_reg))
  | `store (_, src) -> (* FIXME: Verify access size!  *)
      C.Set (C.Unary (Irtypes.Aggr_member (var_type, aggr_access),
		      var_reg), src)
  | `ssa_reg ->
      C.Unary (Irtypes.Address_of,
	       C.Unary (Irtypes.Aggr_member (var_type, aggr_access), var_reg))

let try_rewrite_var vars base offset stack_vars vartype_hash insn rewrite_as
		    ctypes_for_cu =
  match base, vartype_hash with
    C.Nullary Irtypes.Incoming_sp, _ ->
      begin try
	let kvar, var_ofs = known_var vars offset in
	Log.printf 3 "Offset %d looks like variable %s (+%d)\n"
	  offset kvar.Function.var_name var_ofs;
	let sv = CT.Stack_var kvar.Function.var_name in
	stack_vars := IrPhiPlacement.R.add sv !stack_vars;
	let aggr_access, _ =
	  Insn_to_ir.resolve_aggregate_access kvar.Function.var_type var_ofs
					      ctypes_for_cu in
	(*let blk = {
	  Irtypes.ctype = kvar.Function.var_type;
	  block_size = kvar.Function.var_size;
	  access_size = Irtypes.Word
	} in*)
      try_rewrite_access (C.Reg sv) kvar.Function.var_type aggr_access
			 rewrite_as
      with Not_found | Insn_to_ir.Non_aggregate ->
	Log.printf 3 "Not found/non-aggregate at offset %d\n" offset;
	insn
      end
  | C.SSAReg regid, Some vh ->
      begin try
        let vti = Hashtbl.find vh (Vartypes.T_ssareg regid) in
	let aggr_access, _ =
	  Insn_to_ir.resolve_aggregate_access vti.Vartypes.vt_type offset
					      ctypes_for_cu in
	try_rewrite_access base vti.Vartypes.vt_type aggr_access rewrite_as
      with Not_found | Insn_to_ir.Non_aggregate ->
        Log.printf 3 "Type missing or non-aggregate for %s\n"
	  (Typedb.string_of_ssa_reg (fst regid) (snd regid));
	insn
      end
  | C.Reg reg, Some vh ->
      begin try
        let vti = Hashtbl.find vh (Vartypes.T_reg reg) in
	Log.printf 3 "Type for %s is %s\n" (C.string_of_code base)
	  (Ctype.string_of_ctype vti.Vartypes.vt_type);
	let aggr_access, _ =
	  Insn_to_ir.resolve_aggregate_access vti.Vartypes.vt_type offset
					      ctypes_for_cu in
	try_rewrite_access base vti.Vartypes.vt_type aggr_access rewrite_as
      with Not_found | Insn_to_ir.Non_aggregate ->
        Log.printf 3 "Type missing or non-aggregate for %s\n"
	  (CT.string_of_reg reg);
	insn
      end
  | _, _ -> insn

let pointer_tracking blk_arr inforec dwarf_vars ?vartype_hash ctypes_for_cu =
  let defs = get_defs blk_arr in
  let stack_vars = ref IrPhiPlacement.R.empty in
  let blk_arr' = Array.map
    (fun blk ->
      let addr = ref None in
      let code' = CS.fold_left
        (fun codeseq stmt ->
	  match stmt with
	    C.Entity (CT.Insn_address ia) ->
	      addr := Some ia;
	      CS.snoc codeseq stmt
	  | C.Set (dst, C.Load (accsz, addr)) ->
	      begin try
		let offset = Ptrtracking.cfa_offset addr defs in
		let new_stmt =
		  try_rewrite_var dwarf_vars (C.Nullary Irtypes.Incoming_sp)
				  (Int32.to_int offset)
				  stack_vars vartype_hash stmt
				  (`load (accsz, dst)) ctypes_for_cu in
		CS.snoc codeseq new_stmt
	      with Ptrtracking.Not_constant_cfa_offset ->
	        CS.snoc codeseq stmt
	      end
	  | C.Store (accsz, addr, src) ->
	      begin try
		let offset = Ptrtracking.cfa_offset addr defs in
		let new_stmt =
		  try_rewrite_var dwarf_vars (C.Nullary Irtypes.Incoming_sp)
				  (Int32.to_int offset)
				  stack_vars vartype_hash stmt
				  (`store (accsz, src)) ctypes_for_cu in
		CS.snoc codeseq new_stmt
	      with Ptrtracking.Not_constant_cfa_offset ->
	        CS.snoc codeseq stmt
	      end
	  | C.Set (dst, src) ->
	      let src' = C.map
	        (fun addr ->
		  match addr with
		    (C.SSAReg _ | C.Reg _ as base)
		  | C.Binary (Irtypes.Add, (C.SSAReg _ | C.Reg _ as base),
			      C.Immed _)
		  | C.Binary (Irtypes.Sub, (C.SSAReg _ | C.Reg _ as base),
			      C.Immed _)
		      when reg_or_ssareg_probably_pointer base ctypes_for_cu
			     inforec vartype_hash ->
		      begin try
			let offset = Ptrtracking.cfa_offset addr defs in
			let new_var =
			  try_rewrite_var dwarf_vars
					  (C.Nullary Irtypes.Incoming_sp)
					  (Int32.to_int offset) stack_vars
					  vartype_hash addr `ssa_reg
					  ctypes_for_cu in
			new_var
		      with Ptrtracking.Not_constant_cfa_offset ->
		        addr
		      end
		  | x -> x)
		src in
	      CS.snoc codeseq (C.Set (dst, src'))
	  | x -> CS.snoc codeseq x)
	CS.empty
	blk.Block.code in
      { blk with Block.code = code' })
    blk_arr in
  blk_arr', !stack_vars

let rec stack_address_within_var location_list insn_addr sp_offset var_size =
  match insn_addr with
    Some insn_addr' ->
      List.fold_right
        (fun location found ->
	  match location with
            Locations.Within_range (lo, hi, loc)
	      when insn_addr' >= lo && insn_addr' < hi ->
	      found || stack_address_within_var [loc] insn_addr sp_offset
						var_size
	  | Locations.Within_range (lo, hi, loc) ->
	      (*Log.printf 3 "Offset %ld not in %s, %lx not in range %lx-%lx\n" 
	        sp_offset (Location.string_of_location loc) insn_addr' lo hi;*)
	      found
	  | Locations.Parts _ -> failwith "unimplemented"
	  | Locations.In code ->
              begin match code with
		C.Reg (CT.Stack o) ->
		  found || (sp_offset >= Int32.of_int o
			    && sp_offset < Int32.of_int (o + var_size))
	      | _ -> found
	      end)
	location_list
	false
  | None -> false

let resolve_vars blk_arr dwarf_vars addressable =
  List.map
    (fun addressable_ent ->
      try
	let var = List.find
          (fun var ->
	    match var.Function.var_location with
	      Some loclist ->
		let conv_loc = Locations.convert_dwarf_loclist loclist in
		stack_address_within_var conv_loc
		  addressable_ent.Ptrtracking.insn_addr
		  addressable_ent.Ptrtracking.cfa_offset
		  var.Function.var_size
	    | None -> false)
	  dwarf_vars in
	let iaddr_str =
	  Ptrtracking.string_of_optional_insn_addr
	    addressable_ent.Ptrtracking.insn_addr in
	Log.printf 3 "Found var for CFA offset %ld (%s): %s\n"
	  addressable_ent.Ptrtracking.cfa_offset iaddr_str
	  var.Function.var_name;
	{ addressable_ent with Ptrtracking.ent_size =
				 Some var.Function.var_size }
      with Not_found ->
        Log.printf 3 "Can't find var for CFA offset %ld\n"
	  addressable_ent.Ptrtracking.cfa_offset;
	addressable_ent)
    addressable

module OffsetMap = Map.Make
  (struct
    type t = int
    let compare = compare
  end)

type stack_access_kind =
    Saved_caller_reg
  | Outgoing_arg
  | Local_var_or_spill_slot
  | Addressable_local_var

let add_offsetmap_to_blkarr blkarr =
  Block.map_code
    (CS.map (fun stmt -> stmt, ref OffsetMap.empty))
    blkarr

let rec record_kind_for_offset omap offset bytes kind =
  match bytes with
    0 -> omap
  | n ->
      OffsetMap.add offset kind (record_kind_for_offset omap (succ offset)
		    (pred bytes) kind)

exception Mixed

let kind_for_offset_word omap offset =
  let b1 = OffsetMap.find offset omap
  and b2 = OffsetMap.find (offset + 1) omap
  and b3 = OffsetMap.find (offset + 2) omap
  and b4 = OffsetMap.find (offset + 3) omap in
  if b1 = b2 && b2 = b3 && b3 = b4 then
    b1
  else
    raise Mixed

let store defs accsz src offset offsetmap =
  match Ptrtracking.first_src defs src with
    None -> ()
  | Some (C.Nullary Irtypes.Caller_saved, _) ->
      offsetmap := record_kind_for_offset !offsetmap (Int32.to_int offset)
        (Irtypes.access_bytesize accsz) Saved_caller_reg
  | Some _ -> ()

let outgoing_arg defs accsz offset offsetmap =
  offsetmap := record_kind_for_offset !offsetmap (Int32.to_int offset)
    (Irtypes.access_bytesize accsz) Outgoing_arg

let mark_addressable addressable_ent offsetmap =
  match addressable_ent.Ptrtracking.ent_size with
    Some ent_size ->
      offsetmap := record_kind_for_offset !offsetmap
	(Int32.to_int addressable_ent.Ptrtracking.cfa_offset) ent_size
	Addressable_local_var
  | None -> ()

let scan_stack_accesses blkarr addressable entrypoint =
  let defs = get_defs blkarr in
  let num_blks = Array.length blkarr in
  let offsetmap_at_start = Array.make num_blks OffsetMap.empty
  and offsetmap_at_end = Array.make num_blks OffsetMap.empty in
  let blkarr_offsetmap = add_offsetmap_to_blkarr blkarr in
  (* Propagate stores forwards.  *)
  let rec scan_f cur_offsetmap at =
    Log.printf 3 "Propagating to block %d\n" at;
    offsetmap_at_start.(at) <- cur_offsetmap;
    let _, final_offsetmap = CS.fold_left
      (fun (insn_addr, offsetmap_acc) (stmt, stmt_offsetmap) ->
        let ia_ref = ref insn_addr
	and om_ref = ref offsetmap_acc in
        ignore (C.map
	  (fun node ->
	    try
              match node with
	        C.Entity (CT.Insn_address ia) ->
		  ia_ref := Some ia;
		  List.iter
		    (fun addressable_ent ->
		      match addressable_ent.Ptrtracking.insn_addr with
		        Some insn_addr when insn_addr = ia ->
			  mark_addressable addressable_ent om_ref
		      | _ -> ())
		    addressable;
		  node
	      | C.Store (accsz, addr, C.SSAReg src) ->
		  let offset = Ptrtracking.cfa_offset addr defs in
		  store defs accsz src offset om_ref;
		  C.Protect node
	      | _ -> node
	    with Ptrtracking.Not_constant_cfa_offset ->
	      C.Protect node)
	  stmt);
	stmt_offsetmap := !om_ref;
	!ia_ref, !om_ref)
      (None, cur_offsetmap)
      blkarr_offsetmap.(at).Block.code in
    offsetmap_at_end.(at) <- final_offsetmap;
    blkarr_offsetmap.(at).Block.visited <- true;
    List.iter
      (fun blk ->
        let dest_dfnum = blk.Block.dfnum in
        let dest_start = offsetmap_at_start.(dest_dfnum) in
	if not (OffsetMap.equal (=) dest_start final_offsetmap)
	   || not blkarr_offsetmap.(dest_dfnum).Block.visited then
          scan_f final_offsetmap dest_dfnum)
      blkarr_offsetmap.(at).Block.successors in
  (* Propagate loads backwards.  *)
  let rec scan_b cur_offsetmap at =
    Log.printf 3 "Propagating backwards to block %d\n" at;
    offsetmap_at_end.(at) <- cur_offsetmap;
    let _, start_offsetmap = CS.fold_right
      (fun (stmt, stmt_offsetmap) (insn_addr, offsetmap_acc) ->
        let ia_ref = ref insn_addr
	and om_ref = ref offsetmap_acc in
	ignore (C.map
	  (fun node ->
	    try
	      match node with
	        C.Entity (CT.Insn_address ia) ->
		  ia_ref := Some ia;
		  node
	      | _ -> node
	    with Ptrtracking.Not_constant_cfa_offset ->
	      C.Protect node)
	  ~ctl_fn:(fun node ->
	    match node with
	      C.Call_ext (_, _, args, _, _) ->
	        ignore (C.map
		  (fun node ->
		    try
		      match node with
			C.Load (accsz, addr) ->
			  let offset = Ptrtracking.cfa_offset addr defs in
			  outgoing_arg defs accsz offset om_ref;
			  C.Protect node
		      | _ -> node
		    with Ptrtracking.Not_constant_cfa_offset ->
		      C.Protect node)
		  args);
		node
	    | _ -> node)
	  stmt);
	stmt_offsetmap := !om_ref;
	!ia_ref, !om_ref)
      blkarr_offsetmap.(at).Block.code
      (None, cur_offsetmap) in
    offsetmap_at_start.(at) <- start_offsetmap;
    blkarr_offsetmap.(at).Block.visited <- true;
    List.iter
      (fun blk ->
        let dest_dfnum = blk.Block.dfnum in
	let dest_end = offsetmap_at_end.(dest_dfnum) in
	if not (OffsetMap.equal (=) dest_end start_offsetmap)
	   || not blkarr_offsetmap.(dest_dfnum).Block.visited then
	  scan_b start_offsetmap dest_dfnum)
      blkarr_offsetmap.(at).Block.predecessors in
  Block.clear_visited blkarr_offsetmap;
  scan_f OffsetMap.empty entrypoint;
  Block.clear_visited blkarr_offsetmap;
  (* I'm not sure if control always reaches the virtual_exit block: scan all
     the blocks to be sure.  FIXME?  *)
  for i = Array.length blkarr_offsetmap - 1 downto 0 do
    if not blkarr_offsetmap.(i).Block.visited then
      scan_b offsetmap_at_end.(i) i;
  done;
  blkarr_offsetmap

let letter_for_offset_word omap offset =
  try
    match kind_for_offset_word omap offset with
      Saved_caller_reg -> 'R'
    | Outgoing_arg -> 'A'
    | Local_var_or_spill_slot -> 'V'
    | Addressable_local_var -> '&'
  with
    Not_found -> '.'
  | Mixed -> '*'

let string_of_offsetmap om =
  let opt = function
    None -> "*"
  | Some x -> string_of_int x in
  let mini, maxi =
    OffsetMap.fold
      (fun key _ (lo, hi) ->
        begin match lo with
	  None -> Some key
	| Some lo -> Some (min key lo)
	end,
	begin match hi with
	  None -> Some key
	| Some hi -> Some (max key hi)
	end)
      om
      (None, None) in
  let prefix = Printf.sprintf "[%s...%s] " (opt mini) (opt maxi) in
  let buf = Buffer.create 5 in
  begin match mini, maxi with
    Some mini, Some maxi ->
      for i = (maxi - 3) / 4 downto mini / 4 do
	Buffer.add_char buf (letter_for_offset_word om (i * 4))
      done
  | _ -> ()
  end;
  prefix ^ (Buffer.contents buf)


let dump_offsetmap_blkarr barr =
  Array.iter
    (fun block ->
      Log.printf 3 "block id \"%s\":\n" (BS.string_of_blockref block.Block.id);
      ignore (CS.fold_left
        (fun _ (code, offsets) ->
	  Log.printf 3 "%s\t%s\n" (C.string_of_code code)
		     (string_of_offsetmap !offsets))
	()
        block.Block.code))
    barr
