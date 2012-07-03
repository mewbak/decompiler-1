open Dwarfreader

(* This is (so far) a really bad approximation of the C type system!  *)

type ctype =
    C_void
  | C_int
  | C_short
  | C_char
  | C_float
  | C_double
  | C_signed of ctype
  | C_unsigned of ctype
  | C_pointer of ctype
  | C_const of ctype
  | C_volatile of ctype
  | C_struct of aggregate_member list
  | C_union of aggregate_member list
  | C_array of int * ctype
  | C_enum (* of ... *)
  | C_typedef of string
  | C_typetag of string

and aggregate_member = {
  name : string;
  typ : ctype;
  offset : int;
  size : int
}

type ctype_info = {
  ct_typedefs : (string, ctype) Hashtbl.t;
  ct_typetags : (string, ctype) Hashtbl.t
}

let rec pointer_type ct_for_cu ctyp = 
  match ctyp with
    C_pointer _ -> true
  | C_const c | C_volatile c -> pointer_type ct_for_cu c
  | C_typedef td ->
      pointer_type ct_for_cu (Hashtbl.find ct_for_cu.ct_typedefs td)
  | C_typetag tt ->
      pointer_type ct_for_cu (Hashtbl.find ct_for_cu.ct_typetags tt)
  | _ -> false

let string_of_ctype ctyp =
  let rec scan = function
    C_void -> "void"
  | C_int -> "int"
  | C_short -> "short"
  | C_char -> "char"
  | C_float -> "float"
  | C_double -> "double"
  | C_signed x -> "signed " ^ scan x
  | C_unsigned x -> "unsigned " ^ scan x
  | C_const x -> "const " ^ scan x
  | C_volatile x -> "volatile " ^ scan x
  | C_enum -> "enum"
  | C_pointer x -> scan x ^ "*"
  | C_typedef nm -> Printf.sprintf "typedef %s" nm
  | C_typetag nm -> Printf.sprintf "incomplete type %s" nm
  | C_array (num, typ) -> Printf.sprintf "%s[%d]" (scan typ) num
  | C_struct agg ->
      Printf.sprintf "struct { %s }"
        (String.concat ";"
	  (List.map
	    (fun ag ->
	      Printf.sprintf "%s %s; /* offset=%d, size=%d */" (scan ag.typ)
			     ag.name ag.offset ag.size)
	    agg))
  | C_union agg ->
      Printf.sprintf "union { %s }"
        (String.concat ";"
	  (List.map
	    (fun ag ->
	      Printf.sprintf "%s %s; /* offset=%d, size=%d */" (scan ag.typ)
			     ag.name ag.offset ag.size)
	    agg)) in
  scan ctyp

let rec dwarf_type_size die die_hash =
  match die with
    Die_node ((DW_TAG_typedef, attrs), _) ->
      let targ = get_attr_deref attrs DW_AT_type die_hash in
      dwarf_type_size targ die_hash
  | Die_tree ((DW_TAG_array_type, attrs), child, _) ->
      begin match child with
        Die_node ((DW_TAG_subrange_type, attrs), _) ->
	  let upper_bound = get_attr_int attrs DW_AT_upper_bound in
	  let elem_type = get_attr_deref attrs DW_AT_type die_hash in
	  let elsize = dwarf_type_size elem_type die_hash in
	  elsize * (upper_bound + 1)
      | _ -> failwith "can't find array size"
      end
  | Die_node (((DW_TAG_volatile_type | DW_TAG_const_type), attrs), _) ->
      let targ = get_attr_deref attrs DW_AT_type die_hash in
      dwarf_type_size targ die_hash
  | Die_node ((_, attrs), _)
  | Die_tree ((_, attrs), _, _) ->
      begin try
        get_attr_int attrs DW_AT_byte_size
      with Not_found ->
        failwith "No byte size for die"
      end
  | Die_empty -> raise Not_found

exception Unknown_type

exception Unresolved_type of (dwarf_tag
			     * ((dwarf_attribute * attr_datum) list)) die

let rec resolve_type die die_hash ctypes_for_cu =
  let rec build = function
    Die_node ((DW_TAG_typedef, attrs), _) ->
      let typename = get_attr_string attrs DW_AT_name in
      if not (Hashtbl.mem ctypes_for_cu.ct_typedefs typename) then
      begin
	let targ =
          try
	    build (get_attr_deref attrs DW_AT_type die_hash)
	  with Not_found -> C_void in
	Log.printf 4 "Add %s to hash (type %s)\n" typename
	  (string_of_ctype targ);
	Hashtbl.add ctypes_for_cu.ct_typedefs typename targ;
      end;
      C_typedef typename
  | Die_node ((DW_TAG_pointer_type, attrs), _) ->
      let targ = get_attr_deref attrs DW_AT_type die_hash in
      C_pointer (build targ)
  | Die_node ((DW_TAG_const_type, attrs), _) ->
      let targ = get_attr_deref attrs DW_AT_type die_hash in
      C_const (build targ)
  | Die_node ((DW_TAG_volatile_type, attrs), _) ->
      let targ = get_attr_deref attrs DW_AT_type die_hash in
      C_volatile (build targ)
  | Die_tree ((DW_TAG_structure_type, attrs), child, _) ->
      begin try
	let tag_name = get_attr_string attrs DW_AT_name in
	Log.printf 4 "Got struct, tag name %s\n" tag_name;
	if Hashtbl.mem ctypes_for_cu.ct_typetags tag_name then
	  Hashtbl.find ctypes_for_cu.ct_typetags tag_name
	else begin
	  Hashtbl.add ctypes_for_cu.ct_typetags tag_name (C_typetag tag_name);
	  let styp =
	    C_struct (resolve_aggregate child die_hash ctypes_for_cu) in
	  Hashtbl.replace ctypes_for_cu.ct_typetags tag_name styp;
	  styp
	end
      with Not_found ->
        C_struct (resolve_aggregate child die_hash ctypes_for_cu)
      end
  | Die_node ((DW_TAG_structure_type, attrs), _)
  | Die_node ((DW_TAG_union_type, attrs), _) ->
      (* Declaration only.  *)
      let tag_name = get_attr_string attrs DW_AT_name in
      if Hashtbl.mem ctypes_for_cu.ct_typetags tag_name then
        Hashtbl.find ctypes_for_cu.ct_typetags tag_name
      else begin
        let tag_only = C_typetag tag_name in
        Hashtbl.add ctypes_for_cu.ct_typetags tag_name tag_only;
	tag_only
      end
  | Die_tree ((DW_TAG_union_type, attrs), child, _) ->
      begin try
	let tag_name = get_attr_string attrs DW_AT_name in
	if Hashtbl.mem ctypes_for_cu.ct_typetags tag_name then
	  Hashtbl.find ctypes_for_cu.ct_typetags tag_name
	else begin
	  Hashtbl.add ctypes_for_cu.ct_typetags tag_name (C_typetag tag_name);
	  let utyp =
	    C_union (resolve_aggregate child die_hash ctypes_for_cu) in
	  Hashtbl.replace ctypes_for_cu.ct_typetags tag_name utyp;
	  utyp
	end
      with Not_found ->
	C_union (resolve_aggregate child die_hash ctypes_for_cu)
      end
  | Die_tree ((DW_TAG_enumeration_type, attrs), _, _) ->
      C_enum
  | Die_node ((DW_TAG_base_type, attrs), _) as die' ->
      let enc = parse_encoding (get_attr_int attrs DW_AT_encoding)
      and size = get_attr_int attrs DW_AT_byte_size in
      begin match enc, size with
        DW_ATE_signed, 4 -> C_int
      | DW_ATE_unsigned, 4 -> C_unsigned C_int
      | DW_ATE_signed, 2 -> C_short
      | DW_ATE_unsigned, 2 -> C_unsigned C_short
      | (DW_ATE_signed | DW_ATE_signed_char), 1 -> C_signed C_char
      | (DW_ATE_unsigned | DW_ATE_unsigned_char), 1 -> C_unsigned C_char
      | DW_ATE_float, 4 -> C_float
      | DW_ATE_float, 8 -> C_double
      | _ -> raise (Unresolved_type die')
      end
  | Die_tree ((DW_TAG_array_type, _), child, _) as die' ->
      begin match child with
        Die_node ((DW_TAG_subrange_type, attrs), _) ->
	  let upper_bound = get_attr_int attrs DW_AT_upper_bound in
	  let elem_type = get_attr_deref attrs DW_AT_type die_hash in
	  let typ = resolve_type elem_type die_hash ctypes_for_cu in
	  C_array (upper_bound + 1, typ)
      | _ -> raise (Unresolved_type die')
      end
  | Die_tree ((DW_TAG_subroutine_type, _), _, _) ->
      C_void (* unimplemented! *)
  | die' -> raise (Unresolved_type die') in
  build die
  
and resolve_aggregate die die_hash ctypes_for_cu =
  let rec build = function
    Die_empty -> []
  | Die_node ((DW_TAG_member, mem_attrs), next) ->
      let mem_name = get_attr_string mem_attrs DW_AT_name in
      let mem_offset =
        try
	  get_attr_member_loc mem_attrs DW_AT_data_member_location
			      ~addr_size:4
	with Not_found ->
	  (* ??? -- probably a union.  *)
	  0 in
      begin try
	let mem_type = get_attr_deref mem_attrs DW_AT_type die_hash in
	Log.printf 4 "got type for %s\n" mem_name;
	let mem_size = dwarf_type_size mem_type die_hash in
	Log.printf 4 "got size too, %d\n" mem_size;
	let resolved_type = resolve_type mem_type die_hash ctypes_for_cu in
	Log.printf 4 "resolved type to %s\n" (string_of_ctype resolved_type);
	{ name = mem_name; typ = resolved_type; offset = mem_offset;
	  size = mem_size } :: build next
      with Not_found ->
	failwith "no"
      end
  | _ -> raise Unknown_type in
  build die

