(* This file is released under the terms of an MIT-like license.     *)
(* See the attached LICENSE file.                                    *)
(* Copyright 2016 by LexiFi.                                         *)

open Ast_mapper
open Ast_helper
open Asttypes
open Parsetree
open Longident
open Location

let digest x =
  Digest.to_hex (Digest.string (Marshal.to_string x []))

let with_thread = ref false

let error loc code =
  let open Printf in
  let message = function
    | `Too_many_attributes -> "too many attributes"
    | `Expecting_payload l ->
      sprintf "expecting payload in [%s]"
        (String.concat "," (List.map (sprintf "\"%s\"") l))
    | `Payload_not_a_string -> "payload is not a string"
    | `Provide_a_name -> "this landmark annotation requires a name argument"
  in
  raise (Location.Error (Location.error ~loc
                           (Printf.sprintf "ppx_landmark: %s" (message code))))

let landmark_hash = ref ""
let landmark_id = ref 0
let landmarks_to_register = ref []

let has_name key ({txt; _}, _) = txt = key

let remove_attribute key =
  List.filter (fun x -> not (has_name key x))

let has_attribute ?(auto = false) key l =
  if auto || List.exists (has_name key) l then
    Some (remove_attribute key l)
  else
    None

let get_string_payload key = function
    {txt; _}, PStr [{pstr_desc = Pstr_eval ({
        pexp_desc = Pexp_constant (Pconst_string (x, None)); _
      }, _); _}] when txt = key -> Some (Some x)
  | {txt; _}, PStr [] when txt = key -> Some None
  | {txt; loc}, _ when txt = key -> error loc `Payload_not_a_string
  | _ -> None

let has_landmark_attribute ?auto = has_attribute ?auto "landmark"

let payload_of_string x =
  PStr [Str.eval (Exp.constant (Const.string x))]

let var x = Exp.ident (mknoloc (Longident.parse x))

let rec filter_map f = function
  | [] -> []
  | hd :: tl ->
    match f hd with
    | Some x -> x :: (filter_map f tl)
    | None -> filter_map f tl

let string_of_loc (l : Location.t) =
  let file, line, _ = Location.get_pos_info l.loc_start in
  Printf.sprintf "%s:%d" (Location.show_filename file) line

let enter_landmark lm =
  let landmark_enter =
    if !with_thread then "Landmark_threads.enter" else "Landmark.enter"
  in
  Exp.apply (var landmark_enter) [Nolabel, var lm]
let exit_landmark lm =
  let landmark_exit =
    if !with_thread then "Landmark_threads.exit" else "Landmark.exit"
  in
  Exp.apply (var landmark_exit) [Nolabel, var lm]
let register_landmark name location =
  Exp.apply (var "Landmark.register")
    [ Labelled "location", Const.string location |> Exp.constant;
      Nolabel, Const.string name |> Exp.constant]

let new_landmark landmark_name loc =
  incr landmark_id;
  let landmark = Printf.sprintf "__generated_landmark_%s_%d" !landmark_hash !landmark_id in
  let landmark_location = string_of_loc loc in
  landmarks_to_register :=
    (landmark, landmark_name, landmark_location) :: !landmarks_to_register;
  landmark

let qualified ctx name = String.concat "." (List.rev (name :: ctx))

let wrap_landmark ctx landmark_name loc expr =
  let landmark_name = qualified ctx landmark_name in
  let landmark = new_landmark landmark_name loc in
  Exp.sequence (enter_landmark landmark)
    (Exp.let_ Nonrecursive
       [Vb.mk (Pat.var (mknoloc "r"))
          (Exp.try_ expr
             [Exp.case (Pat.var (mknoloc "e"))
                (Exp.sequence
                   (exit_landmark landmark)
                   (Exp.apply (var "Pervasives.raise") [Nolabel, var "e"]))])]
       (Exp.sequence
          (exit_landmark landmark)
          (var "r")))

let rec arity {pexp_desc; _} =
  match pexp_desc with
  | Pexp_fun (a, _, _, e ) -> a :: arity e
  | Pexp_function cases ->
    let max_list l1 l2 =
      if List.length l1 < List.length l2 then
        l1
      else
        l2
    in
    Nolabel :: (List.fold_left
                  (fun acc {pc_rhs; _} -> max_list (arity pc_rhs) acc)
                  [] cases)
  | Pexp_newtype (_, e) -> arity e
  | Pexp_constraint (e, _) -> arity e
  | _ -> []

let eta_expand f t n =
  let vars =
    List.mapi (fun k x -> (x, Printf.sprintf "__x%d" k)) n
  in
  let rec app acc = function
    | [] -> acc
    | (l,x) :: tl -> app (Exp.apply acc [l, Exp.ident (mknoloc (Lident x))]) tl
  in
  let rec lam = function
    | [] -> f (app t vars)
    | (l,x) :: tl -> Exp.fun_ l None (Pat.var (mknoloc x)) (lam tl)
  in
  lam vars

let rec not_a_constant expr = match expr.pexp_desc with
  | Pexp_constant _ | Pexp_ident _ -> false
  | Pexp_coerce (e, _, _) | Pexp_poly (e, _) | Pexp_constraint (e, _) -> not_a_constant e
  | _ -> true

let rec name_of_pattern pat =
  match pat.ppat_desc with
  | Ppat_var {txt; _} -> Some txt
  | Ppat_constraint (pat, _) -> name_of_pattern pat
  | _ -> None

let translate_value_bindings ctx mapper auto vbs =
  let vbs_arity_name =
    List.map
      (fun vb -> match vb, has_landmark_attribute ~auto vb.pvb_attributes with
         | { pvb_expr; pvb_loc; pvb_pat; _}, Some attr
           when not_a_constant pvb_expr ->
           let arity = arity pvb_expr in
           let from_names arity fun_name landmark_name =
             if auto && arity = [] then
               (vb, None)
             else
               (vb, Some (arity, fun_name, landmark_name, pvb_loc, attr))
           in
           (match name_of_pattern pvb_pat,
                  filter_map (get_string_payload "landmark") vb.pvb_attributes
            with
            | Some fun_name, []
            | Some fun_name, [ None ] ->
              from_names arity fun_name fun_name
            | Some fun_name, [ Some landmark_name ] ->
              from_names arity fun_name landmark_name
            | _, [Some name] -> from_names [] "" name
            | _, [] | _, [ _ ] ->
              if auto then (vb, None) else error pvb_loc `Provide_a_name
            | _ -> error pvb_loc `Too_many_attributes)
         | _, _ -> (vb, None))
      vbs
  in
  let vbs = List.map (function
      | (vb, None) ->
        default_mapper.value_binding mapper vb
      | {pvb_pat; pvb_loc; pvb_expr; _}, Some (arity, _, name, loc, attrs) ->
        (* Remove landmark attribute: *)
        let vb =
          Vb.mk ~attrs ~loc:pvb_loc pvb_pat pvb_expr
          |> default_mapper.value_binding mapper
        in
        if arity = [] then
          { vb with pvb_expr = wrap_landmark ctx name loc vb.pvb_expr}
        else
          vb) vbs_arity_name
  in
  let new_vbs = filter_map (function
      | (_, Some (_ :: _ as arity, fun_name, landmark_name, loc, _)) ->
        let ident = Exp.ident (mknoloc (Lident fun_name)) in
        let expr = eta_expand (wrap_landmark ctx landmark_name loc) ident arity in
        Some (Vb.mk (Pat.var (mknoloc fun_name)) expr)
      | _ -> None) vbs_arity_name
  in
  vbs, new_vbs

let rec mapper auto ctx =
  { default_mapper with
    module_binding = (fun _ ({pmb_name; _} as binding) ->
        default_mapper.module_binding (mapper auto (pmb_name.txt :: ctx)) binding
      );
    structure = (fun _ l ->
        let auto = ref auto in
        List.map (function
            | { pstr_desc = Pstr_attribute attr; pstr_loc; _} as pstr ->
              (match get_string_payload "landmark" attr with
               | Some (Some "auto") -> auto := true; []
               | Some (Some "auto-off") -> auto := false; []
               | None -> [pstr]
               | _ -> error pstr_loc (`Expecting_payload ["auto"; "auto-off"]))
            | { pstr_desc = Pstr_value (rec_flag, vbs); pstr_loc} ->
              let mapper = mapper !auto ctx in
              let vbs, new_vbs =
                translate_value_bindings ctx mapper !auto vbs
              in
              let str = Str.value ~loc:pstr_loc rec_flag vbs in
              if new_vbs = [] then [str]
              else
                let warning_off =
                  Str.attribute (mknoloc "ocaml.warning", payload_of_string "-32")
                in
                let include_wrapper = new_vbs
                                      |> Str.value Nonrecursive
                                      |> fun x -> Mod.structure [warning_off; x]
                                                  |> Incl.mk
                                                  |> Str.include_
                in
                [str; include_wrapper]
            | sti ->
              let mapper = mapper !auto ctx in
              [mapper.structure_item mapper sti])
          l |> List.flatten);

    expr =
      fun deep_mapper expr ->
        let expr = match expr with
          | ({pexp_desc = Pexp_let (rec_flag, vbs, body); _} as expr) ->
            let vbs, new_vbs =
              translate_value_bindings ctx deep_mapper false vbs
            in
            let body = deep_mapper.expr deep_mapper body in
            let body =
              if new_vbs = [] then
                body
              else
                Exp.let_ Nonrecursive new_vbs body
            in
            { expr with pexp_desc = Pexp_let (rec_flag, vbs, body) }
          | expr -> default_mapper.expr deep_mapper expr
        in
        let {pexp_attributes; pexp_loc; _} = expr in
        match filter_map (get_string_payload "landmark") pexp_attributes with
        | [Some landmark_name] ->
          { expr with pexp_attributes =
                        remove_attribute "landmark" pexp_attributes }
          |> wrap_landmark ctx landmark_name pexp_loc
        | [ None ] -> error pexp_loc `Provide_a_name
        | [] -> expr
        | _ -> error pexp_loc `Too_many_attributes }

let remove_attributes =
  { default_mapper with
    structure = (fun mapper l ->
        let l =
          List.filter (function {pstr_desc = Pstr_attribute attr; _ }
              when has_landmark_attribute [attr] <> None -> false | _ -> true) l
        in
        default_mapper.structure mapper l);
    attributes = fun mapper attributes ->
      default_mapper.attributes mapper
        (match has_landmark_attribute attributes with
         | Some attrs ->
           attrs
         | None ->
           attributes) }

let has_disable l =
  let disable = ref false in
  let f = function
    | { pstr_desc = Pstr_attribute attr; pstr_loc; _} as pstr ->
      (match get_string_payload "landmark" attr with
       | Some (Some "disable") -> disable := true; None
       | Some (Some "auto-off") | Some (Some "auto") | None -> Some pstr
       | _ -> error pstr_loc
                (`Expecting_payload ["auto"; "auto-off"; "disable"]))
    | i -> Some i
  in
  let res = filter_map f l in
  !disable, res


let toplevel_mapper auto =
  { default_mapper with
    signature = (fun _ -> default_mapper.signature default_mapper);
    structure = fun _ -> function [] -> [] | l ->
      assert (!landmark_hash = "");
      landmark_hash := digest l;
      let disable, l = has_disable l in
      if disable then l else begin
        let first_loc = (List.hd l).pstr_loc in
        let module_name = try Filename.chop_extension !Location.input_name with Invalid_argument _ -> !Location.input_name in
        let mapper = mapper auto [String.capitalize_ascii module_name] in
        let l = mapper.structure mapper l in
        let landmark_name = Printf.sprintf "load(%s)" module_name in
        let lm =
          if auto then
            Some (new_landmark landmark_name first_loc)
          else
            None
        in
        if !landmarks_to_register = [] then l else
          let landmarks =
            Str.value Nonrecursive
              (List.map (fun (landmark, landmark_name, landmark_location) ->
                   Vb.mk (Pat.var (mknoloc landmark))
                     (register_landmark landmark_name landmark_location))
                  (List.rev !landmarks_to_register))
          in
          match lm with
          | Some lm ->
            let begin_load =
              Str.value Nonrecursive
                [Vb.mk (Pat.construct (mknoloc (Longident.parse "()")) None)
                   (enter_landmark lm)]
            in
            let exit_load =
              Str.value Nonrecursive
                [Vb.mk (Pat.construct (mknoloc (Longident.parse "()")) None)
                   (exit_landmark lm)]
            in
            landmarks :: (begin_load :: l @ [exit_load])
          | None ->
            landmarks :: l
      end }
