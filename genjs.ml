(*
 *  Haxe Compiler
 *  Copyright (c)2005 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)
open Type

type ctx = {
	buf : Buffer.t;
	packages : (string list,unit) Hashtbl.t;
	mutable current : tclass;
	mutable statics : (tclass * string * texpr) list;
	mutable inits : texpr list;
	mutable tabs : string;
	mutable in_value : bool;
	mutable handle_break : bool;
	mutable id_counter : int;
}

let s_path = function
	| ([],"@Main") -> "$Main"
	| p -> Ast.s_type_path p

let kwds =
	let h = Hashtbl.create 0 in
	List.iter (fun s -> Hashtbl.add h s ()) [
		"abstract"; "as"; "boolean"; "break"; "byte"; "case"; "catch"; "char"; "class"; "continue"; "const";
		"debugger"; "default"; "delete"; "do"; "double"; "else"; "enum"; "export"; "extends"; "false"; "final";
		"finally"; "float"; "for"; "function"; "goto"; "if"; "implements"; "import"; "in"; "instanceof"; "int";
        "interface"; "is"; "long"; "namespace"; "native"; "new"; "null"; "package"; "private"; "protected";
		"public"; "return"; "short"; "static"; "super"; "switch"; "synchronized"; "this"; "throw"; "throws";
		"transient"; "true"; "try"; "typeof"; "use"; "var"; "void"; "volatile"; "while"; "with"
	];
	h

let field s = if Hashtbl.mem kwds s then "[\"" ^ s ^ "\"]" else "." ^ s
let ident s = if Hashtbl.mem kwds s then "$" ^ s else s

let spr ctx s = Buffer.add_string ctx.buf s
let print ctx = Printf.kprintf (fun s -> Buffer.add_string ctx.buf s)

let unsupported = Typer.error "This expression cannot be compiled to Javascript"

let newline ctx =
	match Buffer.nth ctx.buf (Buffer.length ctx.buf - 1) with
	| '}' | '{' | ':' -> print ctx "\n%s" ctx.tabs
	| _ -> print ctx ";\n%s" ctx.tabs

let rec concat ctx s f = function
	| [] -> ()
	| [x] -> f x
	| x :: l ->
		f x;
		spr ctx s;
		concat ctx s f l

let parent e =
	match e.eexpr with
	| TParenthesis _ -> e
	| _ -> mk (TParenthesis e) e.etype e.epos

let block e =
	match e.eexpr with
	| TBlock (_ :: _) -> e
	| _ -> mk (TBlock [e]) e.etype e.epos

let open_block ctx =
	let oldt = ctx.tabs in
	ctx.tabs <- "\t" ^ ctx.tabs;
	(fun() -> ctx.tabs <- oldt)

let rec iter_switch_break in_switch e =
	match e.eexpr with
	| TFunction _ | TWhile _ | TFor _ -> ()
	| TSwitch _ | TMatch _ when not in_switch -> iter_switch_break true e
	| TBreak when in_switch -> raise Exit
	| _ -> iter (iter_switch_break in_switch) e

let handle_break ctx e =
	let old_handle = ctx.handle_break in
	try
		iter_switch_break false e;
		ctx.handle_break <- false;
		(fun() -> ctx.handle_break <- old_handle)
	with
		Exit ->
			spr ctx "try {";
			let b = open_block ctx in
			newline ctx;
			ctx.handle_break <- true;
			(fun() ->
				b();
				ctx.handle_break <- old_handle;
				newline ctx;
				spr ctx "} catch( e ) { if( e != \"__break__\" ) throw e; }";
			)

let this ctx = if ctx.in_value then "$this" else "this"

let gen_constant ctx p = function
	| TInt i -> print ctx "%ld" i
	| TFloat s -> spr ctx s
	| TString s ->
		if String.contains s '\000' then Typer.error "A String cannot contain \\0 characters" p;
		print ctx "\"%s\"" (Ast.s_escape s)
	| TBool b -> spr ctx (if b then "true" else "false")
	| TNull -> spr ctx "null"
	| TThis -> spr ctx (this ctx)
	| TSuper -> assert false

let rec gen_call ctx e el =
	match e.eexpr , el with
	| TConst TSuper , params ->
		(match ctx.current.cl_super with
		| None -> assert false
		| Some (c,_) ->
			print ctx "%s.apply(%s,[" (s_path c.cl_path) (this ctx);
			concat ctx "," (gen_value ctx) params;
			spr ctx "])";
		);
	| TField ({ eexpr = TConst TSuper },name) , params ->
		(match ctx.current.cl_super with
		| None -> assert false
		| Some (c,_) ->
			print ctx "%s.prototype%s.apply(%s,[" (s_path c.cl_path) (field name) (this ctx);
			concat ctx "," (gen_value ctx) params;
			spr ctx "])";
		);
	| TField (e,s) , el ->
		gen_value ctx e;
		spr ctx (field s);
		spr ctx "(";
		concat ctx "," (gen_value ctx) el;
		spr ctx ")"
	| TCall (x,_) , el when x.eexpr <> TLocal "__js__" ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
		spr ctx "(";
		concat ctx "," (gen_value ctx) el;
		spr ctx ")";
	| TLocal "__new__" , { eexpr = TConst (TString cl) } :: params ->
		print ctx "new %s(" cl;
		concat ctx "," (gen_value ctx) params;
		spr ctx ")";
	| TLocal "__new__" , e :: params ->
		spr ctx "new ";
		gen_value ctx e;
		spr ctx "(";
		concat ctx "," (gen_value ctx) params;
		spr ctx ")";
	| TLocal "__js__", [{ eexpr = TConst (TString code) }] ->
		spr ctx code
	| _ ->
		gen_value ctx e;
		spr ctx "(";
		concat ctx "," (gen_value ctx) el;
		spr ctx ")"

and gen_value_op ctx e =
	match e.eexpr with
	| TBinop (op,_,_) when op = Ast.OpAnd || op = Ast.OpOr || op = Ast.OpXor ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	| _ ->
		gen_value ctx e

and gen_expr ctx e =
	match e.eexpr with
	| TConst c -> gen_constant ctx e.epos c
	| TLocal s -> spr ctx (ident s)
	| TEnumField (e,s) ->
		print ctx "%s%s" (s_path e.e_path) (field s)
	| TArray (e1,e2) ->
		gen_value ctx e1;
		spr ctx "[";
		gen_value ctx e2;
		spr ctx "]";
	| TBinop (op,{ eexpr = TField (e1,s) },e2) ->
		gen_value_op ctx e1;
		spr ctx (field s);
		print ctx " %s " (Ast.s_binop op);
		gen_value_op ctx e2;
	| TBinop (op,e1,e2) ->
		gen_value_op ctx e1;
		print ctx " %s " (Ast.s_binop op);
		gen_value_op ctx e2;
	| TField (x,s) ->
		(match follow e.etype with
		| TFun _ ->
			spr ctx "$closure(";
			gen_value ctx x;
			spr ctx ",";
			gen_constant ctx e.epos (TString s);
			spr ctx ")";
		| _ ->
			gen_value ctx x;
			spr ctx (field s))
	| TTypeExpr t ->
		spr ctx (s_path (t_path t))
	| TParenthesis e ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	| TReturn eo ->
		if ctx.in_value then unsupported e.epos;
		(match eo with
		| None ->
			spr ctx "return"
		| Some e ->
			spr ctx "return ";
			gen_value ctx e);
	| TBreak ->
		if ctx.in_value then unsupported e.epos;
		if ctx.handle_break then spr ctx "throw \"__break__\"" else spr ctx "break"
	| TContinue ->
		if ctx.in_value then unsupported e.epos;
		spr ctx "continue"
	| TBlock [] ->
		spr ctx "null"
	| TBlock el ->
		print ctx "{";
		let bend = open_block ctx in
		List.iter (fun e -> newline ctx; gen_expr ctx e) el;
		bend();
		newline ctx;
		print ctx "}";
	| TFunction f ->
		let old = ctx.in_value in
		ctx.in_value <- false;
		print ctx "function(%s) " (String.concat "," (List.map ident (List.map arg_name f.tf_args)));
		gen_expr ctx (block f.tf_expr);
		ctx.in_value <- old;
	| TCall (e,el) ->
		gen_call ctx e el
	| TArrayDecl el ->
		spr ctx "[";
		concat ctx "," (gen_value ctx) el;
		spr ctx "]"
	| TThrow e ->
		spr ctx "throw ";
		gen_value ctx e;
	| TVars [] ->
		()
	| TVars vl ->
		spr ctx "var ";
		concat ctx ", " (fun (n,_,e) ->
			spr ctx (ident n);
			match e with
			| None -> ()
			| Some e ->
				spr ctx " = ";
				gen_value ctx e
		) vl;
	| TNew (c,_,el) ->
		print ctx "new %s(" (s_path c.cl_path);
		concat ctx "," (gen_value ctx) el;
		spr ctx ")"
	| TIf (cond,e,eelse) ->
		spr ctx "if";
		gen_value ctx (parent cond);
		spr ctx " ";
		gen_expr ctx e;
		(match eelse with
		| None -> ()
		| Some e ->
			newline ctx;
			spr ctx "else ";
			gen_expr ctx e);
	| TUnop (op,Ast.Prefix,e) ->
		spr ctx (Ast.s_unop op);
		gen_value ctx e
	| TUnop (op,Ast.Postfix,e) ->
		gen_value ctx e;
		spr ctx (Ast.s_unop op)
	| TWhile (cond,e,Ast.NormalWhile) ->
		let handle_break = handle_break ctx e in
		spr ctx "while";
		gen_value ctx (parent cond);
		spr ctx " ";
		gen_expr ctx e;
		handle_break();
	| TWhile (cond,e,Ast.DoWhile) ->
		let handle_break = handle_break ctx e in
		spr ctx "do ";
		gen_expr ctx e;
		spr ctx " while";
		gen_value ctx (parent cond);
		handle_break();
	| TObjectDecl fields ->
		spr ctx "{ ";
		concat ctx ", " (fun (f,e) -> print ctx "%s : " f; gen_value ctx e) fields;
		spr ctx "}"
	| TFor (v,it,e) ->
		let handle_break = handle_break ctx e in
		let id = ctx.id_counter in
		ctx.id_counter <- ctx.id_counter + 1;
		print ctx "var $it%d = " id;
		gen_value ctx it;
		newline ctx;
		print ctx "while( $it%d.hasNext() ) { var %s = $it%d.next()" id (ident v) id;
		newline ctx;
		gen_expr ctx e;
		newline ctx;
		spr ctx "}";
		handle_break();
	| TTry (e,catchs) ->
		spr ctx "try ";
		gen_expr ctx (block e);
		newline ctx;
		let id = ctx.id_counter in
		ctx.id_counter <- ctx.id_counter + 1;
		print ctx "catch( $e%d ) {" id;
		let bend = open_block ctx in
		newline ctx;
		let last = ref false in
		List.iter (fun (v,t,e) ->
			if !last then () else
			let t = (match follow t with
			| TEnum (e,_) -> Some (TEnumDecl e)
			| TInst (c,_) -> Some (TClassDecl c)
			| TFun _
			| TLazy _
			| TType _
			| TAnon _ ->
				assert false
			| TMono _
			| TDynamic _ ->
				None
			) in
			match t with
			| None ->
				last := true;
				spr ctx "{";
				let bend = open_block ctx in
				newline ctx;
				print ctx "var %s = $e%d" v id;
				newline ctx;
				gen_expr ctx e;
				bend();
				newline ctx;
				spr ctx "}"
			| Some t ->
				print ctx "if( js.Boot.__instanceof($e%d," id;
				gen_value ctx (mk (TTypeExpr t) (mk_mono()) e.epos);
				spr ctx ") ) {";
				let bend = open_block ctx in
				newline ctx;
				print ctx "var %s = $e%d" v id;
				newline ctx;
				gen_expr ctx e;
				bend();
				newline ctx;
				spr ctx "} else "
		) catchs;
		if not !last then print ctx "throw($e%d)" id;
		bend();
		newline ctx;
		spr ctx "}";
	| TMatch (e,_,cases,def) ->
		spr ctx "var $e = ";
		gen_value ctx e;
		newline ctx;
		spr ctx "switch( $e[0] ) {";
		newline ctx;
		List.iter (fun (constr,params,e) ->
			print ctx "case \"%s\":" constr;
			newline ctx;
			(match params with
			| None | Some [] -> ()
			| Some l ->
				let n = ref 0 in
				let l = List.fold_left (fun acc (v,_) -> incr n; match v with None -> acc | Some v -> (v,!n) :: acc) [] l in
				match l with
				| [] -> ()
				| l ->
					spr ctx "var ";
					concat ctx ", " (fun (v,n) ->
						print ctx "%s = $e[%d]" v n;
					) l;
					newline ctx);
			gen_expr ctx (block e);
			print ctx "break";
			newline ctx
		) cases;
		(match def with
		| None -> ()
		| Some e ->
			spr ctx "default:";
			gen_expr ctx (block e);
			print ctx "break";
			newline ctx;
		);
		spr ctx "}"
	| TSwitch (e,cases,def) ->
		spr ctx "switch";
		gen_value ctx (parent e);
		spr ctx " {";
		newline ctx;
		List.iter (fun (e1,e2) ->
			spr ctx "case ";
			gen_value ctx e1;
			spr ctx ":";
			gen_expr ctx (block e2);
			print ctx "break";
			newline ctx;
		) cases;
		(match def with
		| None -> ()
		| Some e ->
			spr ctx "default:";
			gen_expr ctx (block e);
			print ctx "break";
			newline ctx;
		);
		spr ctx "}"

and gen_value ctx e =
	let assign e =
		mk (TBinop (Ast.OpAssign,
			mk (TLocal "$r") t_dynamic e.epos,
			e
		)) e.etype e.epos
	in
	let value block =
		let old = ctx.in_value in
		ctx.in_value <- true;
		spr ctx "function($this) ";
		let b = if block then begin
			spr ctx "{";
			let b = open_block ctx in
			newline ctx;
			spr ctx "var $r";
			newline ctx;
			b
		end else
			(fun() -> ())
		in
		(fun() ->
			if block then begin
				newline ctx;
				spr ctx "return $r";
				b();
				newline ctx;
				spr ctx "}";
			end;
			ctx.in_value <- old;
			print ctx "(%s)" (this ctx)
		)
	in
	match e.eexpr with
	| TConst _
	| TLocal _
	| TEnumField _
	| TArray _
	| TBinop _
	| TField _
	| TTypeExpr _
	| TParenthesis _
	| TObjectDecl _
	| TArrayDecl _
	| TCall _
	| TNew _
	| TUnop _
	| TFunction _ ->
		gen_expr ctx e
	| TReturn _
	| TBreak
	| TContinue ->
		unsupported e.epos
	| TVars _
	| TFor _
	| TWhile _
	| TThrow _ ->
		(* value is discarded anyway *)
		let v = value true in
		gen_expr ctx e;
		v()
	| TBlock [e] ->
		gen_value ctx e
	| TBlock el ->
		let v = value true in
		let rec loop = function
			| [] ->
				spr ctx "return null";
			| [e] ->
				gen_expr ctx (assign e);
			| e :: l ->
				gen_expr ctx e;
				newline ctx;
				loop l
		in
		loop el;
		v();
	| TIf (cond,e,eo) ->
		spr ctx "(";
		gen_value ctx cond;
		spr ctx "?";
		gen_value ctx e;
		spr ctx ":";
		(match eo with
		| None -> spr ctx "null"
		| Some e -> gen_value ctx e);
		spr ctx ")"
	| TSwitch (cond,cases,def) ->
		let v = value true in
		gen_expr ctx (mk (TSwitch (cond,
			List.map (fun (e1,e2) -> (e1,assign e2)) cases,
			match def with None -> None | Some e -> Some (assign e)
		)) e.etype e.epos);
		v()
	| TMatch (cond,enum,cases,def) ->
		let v = value true in
		gen_expr ctx (mk (TMatch (cond,enum,
			List.map (fun (constr,params,e) -> (constr,params,assign e)) cases,
			match def with None -> None | Some e -> Some (assign e)
		)) e.etype e.epos);
		v()
	| TTry (b,catchs) ->
		let v = value true in
		gen_expr ctx (mk (TTry (assign b,
			List.map (fun (v,t,e) -> v, t , assign e) catchs
		)) e.etype e.epos);
		v()

let generate_package_create ctx (p,_) =
	let rec loop acc = function
		| [] -> ()
		| p :: l when Hashtbl.mem ctx.packages (p :: acc) -> loop (p :: acc) l
		| p :: l ->
			Hashtbl.add ctx.packages (p :: acc) ();
			(match acc with
			| [] ->
				print ctx "%s = {}" p;
			| _ ->
				print ctx "%s%s = {}" (String.concat "." (List.rev acc)) (field p));
			newline ctx;
			loop (p :: acc) l
	in
	loop [] p

let gen_class_static_field ctx c f =
	match f.cf_expr with
	| None ->
		print ctx "%s%s = null" (s_path c.cl_path) (field f.cf_name);
		newline ctx
	| Some e ->
		let e = Transform.block_vars e in
		match e.eexpr with
		| TFunction _ ->
			print ctx "%s%s = " (s_path c.cl_path) (field f.cf_name);
			gen_value ctx e;
			newline ctx
		| _ ->
			ctx.statics <- (c,f.cf_name,e) :: ctx.statics

let gen_class_field ctx c f =
	print ctx "%s.prototype%s = " (s_path c.cl_path) (field f.cf_name);
	match f.cf_expr with
	| None ->
		print ctx "null";
		newline ctx
	| Some e ->
		gen_value ctx (Transform.block_vars e);
		newline ctx

let generate_class ctx c =
	ctx.current <- c;
	let p = s_path c.cl_path in
	generate_package_create ctx c.cl_path;
	print ctx "%s = " p;
	(match c.cl_constructor with
	| Some { cf_expr = Some e } -> gen_value ctx (Transform.block_vars e)
	| _ -> print ctx "function() { }");
	newline ctx;
	print ctx "%s.__name__ = [%s]" p (String.concat "," (List.map (fun s -> Printf.sprintf "\"%s\"" (Ast.s_escape s)) (fst c.cl_path @ [snd c.cl_path])));
	newline ctx;
	(match c.cl_super with
	| None -> ()
	| Some (csup,_) ->
		let psup = s_path csup.cl_path in
		print ctx "%s.__super__ = %s" p psup;
		newline ctx;
		print ctx "for(var k in %s.prototype ) %s.prototype[k] = %s.prototype[k]" psup p psup;
		newline ctx;
	);
	List.iter (gen_class_static_field ctx c) c.cl_ordered_statics;
	PMap.iter (fun _ f -> gen_class_field ctx c f) c.cl_fields;
	print ctx "%s.prototype.__class__ = %s" p p;
	newline ctx;
	match c.cl_implements with
	| [] -> ()
	| l ->
		print ctx "%s.__interfaces__ = [%s]" p (String.concat "," (List.map (fun (i,_) -> s_path i.cl_path) l));
		newline ctx

let generate_enum ctx e =
	let p = s_path e.e_path in
	generate_package_create ctx e.e_path;
	print ctx "%s = { __ename__ : [%s] }" p (String.concat "," (List.map (fun s -> Printf.sprintf "\"%s\"" (Ast.s_escape s)) (fst e.e_path @ [snd e.e_path])));
	newline ctx;
	PMap.iter (fun _ f ->
		print ctx "%s%s = " p (field f.ef_name);
		(match f.ef_type with
		| TFun (args,_) ->
			let sargs = String.concat "," (List.map arg_name args) in
			print ctx "function(%s) { var $x = [\"%s\",%s]; $x.__enum__ = %s; return $x; }" sargs f.ef_name sargs p;
		| _ ->
			print ctx "[\"%s\"]" f.ef_name;
			newline ctx;
			print ctx "%s%s.__enum__ = %s" p (field f.ef_name) p;
		);
		newline ctx
	) e.e_constrs

let generate_static ctx (c,f,e) =
	print ctx "%s%s = " (s_path c.cl_path) (field f);
	gen_value ctx e;
	newline ctx

let generate_type ctx = function
	| TClassDecl c ->
		(match c.cl_init with
		| None -> ()
		| Some e -> ctx.inits <- Transform.block_vars e :: ctx.inits);
		if not c.cl_extern then generate_class ctx c
	| TEnumDecl e when e.e_extern ->
		()
	| TEnumDecl e -> generate_enum ctx e
	| TTypeDecl _ -> ()

let generate file types hres =
	let ctx = {
		buf = Buffer.create 16000;
		packages = Hashtbl.create 0;
		statics = [];
		inits = [];
		current = null_class;
		tabs = "";
		in_value = false;
		handle_break = false;
		id_counter = 0;
	} in
	List.iter (generate_type ctx) types;
	print ctx "js.Boot.__res = {}";
	newline ctx;
	Hashtbl.iter (fun name data ->
		if String.contains data '\000' then failwith ("Resource " ^ name ^ " contains \\0 characters that can't be used in JavaScript");
		print ctx "js.Boot.__res[\"%s\"] = \"%s\"" (Ast.s_escape name) (Ast.s_escape data);
		newline ctx;
	) hres;
	print ctx "js.Boot.__init()";
	newline ctx;
	List.iter (fun e ->
		gen_expr ctx e;
		newline ctx;
	) (List.rev ctx.inits);
	List.iter (generate_static ctx) (List.rev ctx.statics);
	let ch = open_out file in
	output_string ch (Buffer.contents ctx.buf);
	close_out ch
