(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel
open ServerCommandTypes.Method_jumps
open Typing_defs

module Reason = Typing_reason
module TLazyHeap = Typing_lazy_heap
module Cls = Typing_classes_heap

let string_filter_to_method_jump_filter = function
  | "No_filter" -> Some No_filter
  | "Class" -> Some Class
  | "Interface" -> Some Interface
  | "Trait" -> Some Trait
  | _ -> None

(* Used so the given input doesn't need the `\`. *)
let add_ns name =
  if name.[0] = '\\' then name else "\\" ^ name

let get_overridden_methods tcopt origin_class get_or_method dest_class acc =
  match TLazyHeap.get_class tcopt dest_class with
  | None -> acc
  | Some dest_class ->
    (* Check if each destination method exists in the origin *)
    Sequence.fold (Cls.methods dest_class) ~init:acc ~f:begin fun acc (m_name, de_mthd) ->
      (* Filter out inherited methods *)
      if de_mthd.ce_origin <> (Cls.name dest_class) then acc else
      let or_mthd = get_or_method m_name in
      match or_mthd with
      | Some or_mthd when or_mthd.ce_origin = origin_class ->
        let get_pos (lazy ty) =
          ty |> fst |> Reason.to_pos |> Pos.to_absolute in
        {
          orig_name = m_name;
          orig_pos = get_pos or_mthd.ce_type;
          dest_name = m_name;
          dest_pos = get_pos de_mthd.ce_type;
          orig_p_name = origin_class;
          dest_p_name = (Cls.name dest_class);
        } :: acc
      | Some _
      | None -> acc
    end

let check_if_extends_class_and_find_methods tcopt target_class_name get_method
      target_class_pos class_name acc =
  let class_ = TLazyHeap.get_class tcopt class_name in
  match class_ with
  | None -> acc
  | Some c
      when Cls.has_ancestor c target_class_name ->
        let acc = get_overridden_methods tcopt
                      target_class_name get_method
                      class_name
                      acc in {
          orig_name = target_class_name;
          orig_pos = Pos.to_absolute target_class_pos;
          dest_name = (Cls.name c);
          dest_pos = Pos.to_absolute (Cls.pos c);
          orig_p_name = "";
          dest_p_name = "";
        } :: acc
  | _ -> acc

let filter_extended_classes tcopt target_class_name get_method target_class_pos
      acc classes =
  List.fold_left classes ~init:acc ~f:begin fun acc cid ->
    check_if_extends_class_and_find_methods
      tcopt target_class_name get_method target_class_pos (snd cid) acc
  end

let find_extended_classes_in_files tcopt target_class_name get_method
      target_class_pos acc classes =
  List.fold_left classes ~init:acc ~f:begin fun acc classes ->
    filter_extended_classes tcopt target_class_name get_method target_class_pos
      acc classes
  end

let find_extended_classes_in_files_parallel tcopt workers target_class_name
      get_method target_class_pos files_info files =
  let classes = Relative_path.Set.fold files ~init:[] ~f:begin fun fn acc ->
    let { FileInfo.classes; _ } = Relative_path.Map.find_unsafe files_info fn in
    classes :: acc
  end in

  if List.length classes > 10 then
    MultiWorker.call
      workers
      ~job:(find_extended_classes_in_files
        tcopt target_class_name get_method target_class_pos)
      ~merge:(List.rev_append)
      ~neutral:([])
      ~next:(MultiWorker.next workers classes)
  else
    find_extended_classes_in_files tcopt
        target_class_name get_method target_class_pos [] classes

(* Find child classes *)
let get_child_classes_and_methods tcopt cls ~filter files_info workers =
  if filter <> No_filter
  then failwith "Method jump filters not implemented for finding children";
  let files = FindRefsService.get_child_classes_files (Cls.name cls) in
  find_extended_classes_in_files_parallel tcopt
    workers (Cls.name cls) (Cls.get_method cls) (Cls.pos cls) files_info files

let class_passes_filter ~filter cls =
  match filter, cls with
  | No_filter, _ -> true
  | Class, cls when Cls.kind cls = Ast.Cnormal -> true
  | Class, cls when Cls.kind cls = Ast.Cabstract -> true
  | Interface, cls when Cls.kind cls = Ast.Cinterface -> true
  | Trait, cls when Cls.kind cls = Ast.Ctrait -> true
  | _ ->
    false

(* Find ancestor classes *)
let get_ancestor_classes_and_methods tcopt cls ~filter acc =
  let class_ = TLazyHeap.get_class tcopt (Cls.name cls) in
  match class_ with
  | None -> []
  | Some cls ->
      Sequence.fold (Cls.all_ancestor_names cls) ~init:acc ~f:begin fun acc k ->
        let class_ = TLazyHeap.get_class tcopt k in
        match class_ with
        | Some c
          when class_passes_filter ~filter c ->
            let acc = get_overridden_methods tcopt
                          (Cls.name cls)
                          (Cls.get_method cls)
                          (Cls.name c)
                          acc in {
              orig_name = Utils.strip_ns (Cls.name cls);
              orig_pos = Pos.to_absolute (Cls.pos cls);
              dest_name = Utils.strip_ns (Cls.name c);
              dest_pos = Pos.to_absolute (Cls.pos c);
              orig_p_name = "";
              dest_p_name = "";
            } :: acc
        | _ -> acc
      end

(*  Returns a list of the ancestor or child
 *  classes and methods for a given class
 *)
let get_inheritance tcopt class_ ~filter ~find_children files_info workers =
  let class_ = add_ns class_ in
  let class_ = TLazyHeap.get_class tcopt class_ in
  match class_ with
  | None -> []
  | Some c ->
    if find_children then
      get_child_classes_and_methods tcopt c ~filter files_info workers
    else get_ancestor_classes_and_methods tcopt c ~filter []
