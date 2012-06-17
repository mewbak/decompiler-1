(* General handling for splitting sections up into ranges.  This can be used
   for handling mapping symbols, or for chopping up sections like .rodata
   into pieces.  (Unless we can do the latter fully and without gaps, we
   probably can't do better than dumping the section as-is into the decompiled
   program as a char array, and indexing into that.)   *)

type 'a interval =
    (* Start only.  *)
    Half_open of 'a * int32
    (* start, length.  *)
  | Range of 'a * int32 * int32
    (* start, length, padded length.  *)
  | Padded_range of 'a * int32 * int32 * int32

type 'a coverage = {
  mutable intervals : 'a interval array;
  mutable nested_in_prev : bool array;
  mutable raw_intervals : 'a interval list;
  mutable valid : bool;
  start : int32;
  length : int32
}

let create_coverage start length = {
  intervals = [| |];
  nested_in_prev = [| |];
  raw_intervals = [];
  valid = true;
  start = start;
  length = length
}

let interval_start = function
    Half_open (_, start) -> start
  | Range (_, start, _) -> start
  | Padded_range (_, start, _, _) -> start

let interval_type = function
    Half_open (x, _)
  | Range (x, _, _)
  | Padded_range (x, _, _, _) -> x

let interval_matches interval addr =
  match interval with
    Half_open (_, start) -> addr >= start
  | Range (_, start, length) -> addr >= start && addr < (Int32.add start length)
  | Padded_range (_, start, _, padded_length) ->
      addr >= start && addr < (Int32.add start padded_length)

(* True if interval FIRST is strictly within interval SECOND.  *)

let rec interval_within second first =
  match first with
    Half_open (_, start) -> interval_start second >= start
  | Range (_, first_start, first_length)
  | Padded_range (_, first_start, _, first_length) ->
      let first_end = Int32.add first_start first_length in
      begin match second with
        Half_open (_, second_start) ->
	  second_start >= first_start && second_start < first_end
      | Range (_, second_start, second_length)
      | Padded_range (_, second_start, _, second_length) ->
          let second_end = Int32.add second_start second_length in
          second_start >= first_start && second_end <= first_end
      end

(* Sort intervals, and determine those which are nested completely inside their
   predecessors.  *)

let fix_coverage coverage =
  if not coverage.valid then begin
    let sorted = Array.of_list coverage.raw_intervals in
    Array.sort
      (fun a b -> compare (interval_start a) (interval_start b))
      sorted;
    coverage.nested_in_prev <- Array.create (Array.length sorted) false;
    let prev = ref None in
    for i = 0 to Array.length sorted - 1 do
      begin match !prev with
        Some prev ->
	  if interval_within sorted.(i) prev then
	    coverage.nested_in_prev.(i) <- true
      | None -> ()
      end;
      prev := Some sorted.(i)
    done;
    coverage.intervals <- sorted;
    coverage.valid <- true
  end

let add_range coverage interval =
  coverage.raw_intervals <- interval :: coverage.raw_intervals;
  coverage.valid <- false

let rec find_innermost_matching coverage index addr =
  if interval_matches coverage.intervals.(index) addr then
    index
  else if index > 0 && coverage.nested_in_prev.(index) then
    find_innermost_matching coverage (pred index) addr
  else
    raise Not_found

(* Find a stack of intervals which match ADDR, from innermost (head of list)
   to outermost.  This only works for inner ranges which are completely
   nested within each other: otherwise the range with the highest matching
   start address is returned.
   The idea is that we can get useful data from e.g. constant data composed
   from nested struct initialisers.  *)

let find_range_stack coverage addr =
  fix_coverage coverage;
  let rec find low high =
    if low = high then
      failwith "find_range_stack failed"
    else if low = high - 1 then begin
      try
	(* This is the winning condition.  *)
	let win = find_innermost_matching coverage low addr in
	let rec build_result idx =
	  if idx == 0 || not coverage.nested_in_prev.(idx) then
	    [coverage.intervals.(idx)]
	  else
	    coverage.intervals.(idx) :: build_result (pred idx) in
	build_result win
      with Not_found ->
	[]
    end else begin
      let mid = (low + high) / 2 in
      (* The condition should pass for LOW and fail for HIGH.  We should
	 maintain that invariant.  *)
      if addr >= interval_start coverage.intervals.(mid) then
	find mid high
      else
	find low mid
    end in
  (* Note: end point is one place beyond the end of the array.  *)
  find 0 (Array.length coverage.intervals)

(* Find just the innermost range, or raise Not_found.  *)

let find_range coverage addr =
  match find_range_stack coverage addr with
    [] -> raise Not_found
  | res::_ -> res

(*
    |=====first======|
       |======second======|
*)


(*let r = create_coverage 100l 200l

let _ =
  add_range r (Half_open ("whatever", 100l));
  add_range r (Half_open ("blah", 120l));
  add_range r (Half_open ("foo", 150l))
*)

(*let r = create_coverage 100l 200l

let _ =
  add_range r (Range ("first", 100l, 10l));
  add_range r (Range ("second", 120l, 10l));
  add_range r (Range ("third", 130l, 20l));
  add_range r (Range ("fourth", 135l, 5l))
*)
