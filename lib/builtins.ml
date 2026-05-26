(* Central registry: maps built-in compiler roles to the stdlib names they
   bind to.  This is the single place where compiler code names a stdlib
   entity.  Every operator, do-notation hook, and special-syntax construct
   belongs here; the stdlib provides the actual definitions. *)

type iface_role = {
  role     : string;        (* internal key, e.g. "num" *)
  iface    : string;        (* stdlib interface name, e.g. "Num" *)
  arity    : int;           (* number of type parameters *)
  methods  : string list;   (* method names the compiler relies on *)
}

type ctor_role = {
  role  : string;   (* internal key, e.g. "option-some" *)
  ctor  : string;   (* constructor name, e.g. "Some" *)
  arity : int;      (* 0 = nullary, 1 = unary, etc. *)
}

(* operator → (iface_name, method_name)
   Used by binop_type in the type checker (Step 4 migration). *)
let operator_iface : (string * string * string) list = [
  ("+",  "Num",       "add");
  ("-",  "Num",       "sub");
  ("*",  "Num",       "mul");
  ("/",  "Num",       "div");
  ("<",  "Ord",       "lt");
  (">",  "Ord",       "gt");
  ("<=", "Ord",       "lte");
  (">=", "Ord",       "gte");
  ("++", "Semigroup", "append");
]

(* Interfaces the compiler relies on for syntax / operator dispatch. *)
let ifaces : iface_role list = [
  { role = "num";       iface = "Num";       arity = 1;
    methods = ["add"; "sub"; "mul"; "div"] };
  { role = "ord";       iface = "Ord";       arity = 1;
    methods = ["compare"] };
  { role = "semigroup"; iface = "Semigroup"; arity = 1;
    methods = ["append"] };
  { role = "eq";        iface = "Eq";        arity = 1;
    methods = ["eq"] };
  { role = "show";      iface = "Show";      arity = 1;
    methods = ["show"] };
  { role = "thenable";  iface = "Thenable";  arity = 1;
    methods = ["andThen"] };
  { role = "mappable";  iface = "Mappable";  arity = 1;
    methods = ["map"] };
]

(* Constructors the compiler hard-codes in pattern matching / monad dispatch. *)
let ctors : ctor_role list = [
  { role = "bool-true";      ctor = "True";  arity = 0 };
  { role = "bool-false";     ctor = "False"; arity = 0 };
  { role = "option-some";    ctor = "Some";  arity = 1 };
  { role = "option-none";    ctor = "None";  arity = 0 };
  { role = "result-ok";      ctor = "Ok";    arity = 1 };
  { role = "result-err";     ctor = "Err";   arity = 1 };
  { role = "ordering-lt";    ctor = "Lt";    arity = 0 };
  { role = "ordering-eq-ctor"; ctor = "Eq";  arity = 0 };
  { role = "ordering-gt";    ctor = "Gt";    arity = 0 };
]

(* The interface that drives do-notation dispatch. *)
let monad_iface = "Thenable"
