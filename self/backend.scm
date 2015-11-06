;; -*- Mode: Irken -*-

(include "self/cps.scm")
(include "self/typing.scm")
(include "self/graph.scm")
(include "self/analyze.scm")

;;; notes about ctailfun branch:
;;; what we want to experiment with is llvm's claim that it properly
;;;   implements tail calls.
;;; so every function will be emitted as a separate void C function
;;;   that makes only tail calls.
;;; changes needed:
;;;   * 1) emit each function separately
;;;   * 2) change header.c to use an exit_continuation function
;;;   * 3) initialize k to exit_continuation rather than &&Lreturn
;;;   * 4) change PXLL_RETURN macro
;;;   * 5) change known funcalls to call the c function directly
;;; that should be it.
;;;
;;; other things: the 'vm' function needs to be emitted separately,
;;;   maybe change the name to 'toplevel' or something?
;;; closures need to point to function
;;;
;;; every non-tail call needs to split the function in two.
;;; every conditional...
;;; every nvcase...
;;; every fatbar needs to be split into two

;;; theoretically we could scan these continuations for non-tail calls,
;;;   and not bother to emit as a separate function.  perhaps if the compiler
;;;   can learn enough to put it back inline?

;;; -O  6.29s
;;; -O1 7.60s
;;; -O2 6.18s
;;; -O3 6.17s

(define (make-writer file)
  (let ((level 0))
    (define (write-string s)
      (write file.fd
	     (format (repeat level "  ") s "\n"))
      #u)
    (define (copy s)
      (write file.fd s))
    (define (indent) (set! level (+ level 1)))
    (define (dedent) (set! level (- level 1)))
    (define (close-file) (close file.fd))
    {write=write-string indent=indent dedent=dedent copy=copy close=close-file}
    ))

(define (make-name-frobber)
  (define safe-name-map
    (literal
     (alist/make
      (#\! "_bang")
      (#\* "_splat")
      (#\? "_question")
      (#\- "_")
      (#\+ "_plus")
      (#\% "_percent")
      )))
  (define c-legal? (char-class (string->list "abcdefghijklmnopqrstuvwxyz_0123456789")))
  (define (frob-name name)
    (define (frob)
      (let loop ((i 0) (r '()))
	(if (= i (string-length name))
	    r
	    (let ((ch (string-ref name i)))
	      (loop (+ i 1)
		    (list:cons
		     (if (c-legal? ch)
			 (char->string ch)
			 (match (alist/lookup safe-name-map ch) with
			   (maybe:yes sub) -> sub
			   (maybe:no)      -> (format "_" (hex (char->ascii ch)))))
		     r))))))
    (let ((r (string-concat (reverse (frob)))))
      (if (string=? r "_")
	  ;; special-case
	  "minus"
	  r)))
  frob-name)

(define frob-name (make-name-frobber))

(define (gen-function-cname sym n)
  (format "FUN_" (frob-name (symbol->string sym)) "_" (int n)))

(define label-maker
  (let ((counter (make-counter 0)))
    (lambda ()
      (format "L" (int (counter.inc))))))

(define encode-immediate
  (literal:int n)   -> (logior 1 (<< n 1))
  (literal:char ch) -> (logior 2 (<< (char->ascii ch) 8))
  (literal:undef)   -> #x0e
  (literal:cons 'bool 'true _) -> #x106
  (literal:cons 'bool 'false _) -> #x006
  x -> (error1 "expected immediate literal " x))

;; provide automatic conversions of base types for inputs to %%cexp
(define (wrap-in type arg)
  (match type with
    (type:tvar id _) -> arg
    (type:pred name predargs _)
    -> (match name with
	 'int	       -> (format "unbox(" arg ")")
	 'bool         -> (format "PXLL_IS_TRUE(" arg ")")
	 'string       -> (format "((pxll_string*)(" arg "))->data")
	 'cstring      -> (format "(char*)" arg)
	 'buffer       -> (format "(" (irken-type->c-type type) "(((pxll_vector*)" arg ")+1))")
	 'ptr	       -> arg
	 'arrow	       -> arg
	 'vector       -> arg
	 'symbol       -> arg
	 'char	       -> arg
	 'continuation -> arg
	 'raw	       -> (match predargs with
			    ((type:pred 'string _ _)) -> (format "((pxll_string*)(" arg "))")
			    _ -> (error1 "unknown raw type in %cexp" type))
	 kind          -> (if (member-eq? kind c-int-types)
			      (format "unbox(" arg ")")
			      (error1 "wrap-in:" type))
	 )))

;; (buffer (struct sockaddr_t)) => (struct sockaddr_t *)
(define (irken-type->c-type t)
  (match t with
    (type:pred 'buffer (arg) _)	-> (format "(" (irken-type->c-type arg) "*)")
    (type:pred 'struct (arg) _) -> (format "struct " (irken-type->c-type arg))
    (type:pred name () _)	-> (format (sym name))
    _ -> (error1 "malformed ctype" (type-repr t))))

;;
;; ok, for *now*, I don't really want subtyping.  but I *do* want
;;  automatic casting/conversion... what's the cleanest way to get that?
;; We have to deal with both typing and code generation.
;;

(define c-int-types
  ;; XXX distinguish between signed and unsigned!
  ;; XXX also need to handle 64-bit types on a 32-bit platform.
  '(uint8_t uint16_t uint32_t uint64_t
    int8_t int16_t int32_t int64_t))

(define (wrap-out type exp)
  (match type with
    (type:pred 'int _ _)     -> (format "box((pxll_int)" exp ")")
    (type:pred 'bool _ _)    -> (format "PXLL_TEST(" exp ")")
    (type:pred 'cstring _ _) -> (format "(object*)" exp)
    (type:pred 'ptr _ _)     -> (format "(object*)" exp)
    (type:pred kind _ _)     -> (if (member-eq? kind c-int-types)
				    (format "box((pxll_int)" exp ")")
				    exp)
    _			     -> exp
    ))

;; substitute <values> into <template>, e.g. "%0 + %1" ("unbox(r3)" "unbox(r5)") => "r3
(define (cexp-subst template values)
  (let ((split (string-split template #\%)))
    (let loop ((r (LIST (car split)))
	       (l (cdr split)))
      (match l with
	;; wouldn't it be cool to generalize pattern matching to strings somehow?
	()	    -> (string-concat (reverse r))
	("")	    -> (error1 "malformed cexp template string" template) ;; template should not end with %
	("" x . tl) -> (loop (prepend x "%" r) tl) ;; %% causes this
	(x  . tl)   -> (match (alist/lookup dec-map (string-ref x 0)) with
			  (maybe:no)	-> (error1 "malformed cexp template string" template)
			  (maybe:yes n) -> (loop (prepend (substring x 1 (string-length x))
							  (nth values n)
							  r)
						 tl))))))

(define (find-jumps insns)
  (let ((used (map-maker <)))
    (walk-insns
     (lambda (insn _)
       (match insn with
	 (insn:jump reg target num free)
	 -> (match (used::get num) with
	      (maybe:yes _) -> #u
	      (maybe:no)    -> (used::add num (if (> target 0)
						  (list:cons target free)
						  free
						  )))
	 _ -> #u))
     insns)
    used))

(define (emit o decls insns)

  (let ((fun-stack '())
	(current-function-cname "")
	(current-function-name 'toplevel)
	(current-function-part (make-counter 1))
	(env-counter (make-counter 0))
	(env-stack '())
	(used-jumps (find-jumps insns))
	(fatbar-free (map-maker <))
	(declared (set2-maker string<?))
	)

    (define emitk
      (cont:k _ _ k) -> (emit k)
      (cont:nil)     -> #u)

    (define (emit insn)
      (emitk
       (match insn with
	 (insn:return target)			      -> (begin (o.write (format "PXLL_RETURN(" (int target) ");")) (cont:nil))
	 (insn:literal lit k)			      -> (begin (emit-literal lit (k/target k)) k)
	 (insn:litcon i kind k)			      -> (begin (emit-litcon i kind (k/target k)) k)
	 (insn:test reg jn k0 k1 k)		      -> (begin (emit-test reg jn k0 k1 k) (cont:nil))
	 (insn:testcexp regs sig tmpl jn k0 k1 k)     -> (begin (emit-testcexp regs sig tmpl jn k0 k1 k) (cont:nil))
	 (insn:jump reg target jn free)		      -> (begin (emit-jump reg target jn free) (cont:nil))
	 (insn:cexp sig type template args k)	      -> (begin (emit-cexp sig type template args (k/target k)) k)
	 (insn:close name nreg body k)		      -> (begin (emit-close name nreg body (k/target k)) k)
	 (insn:varref d i k)			      -> (begin (emit-varref d i (k/target k)) k)
	 (insn:varset d i v k)			      -> (begin (emit-varset d i v (k/target k)) k)
	 (insn:new-env size top? types k)	      -> (begin (emit-new-env size top? types (k/target k)) k)
	 (insn:alloc tag size k)		      -> (begin (emit-alloc tag size (k/target k)) k)
	 (insn:store off arg tup i k)		      -> (begin (emit-store off arg tup i) k)
	 (insn:invoke name fun args k)		      -> (begin (emit-call name fun args k) (cont:nil))
	 (insn:tail name fun args)		      -> (begin (emit-tail name fun args) (cont:nil))
	 (insn:trcall d n args)			      -> (begin (emit-trcall d n args) (cont:nil))
	 (insn:push r k)			      -> (begin (emit-push r) k)
	 (insn:pop r k)				      -> (begin (emit-pop r (k/target k)) k)
	 (insn:primop name parm t args k)	      -> (begin (emit-primop name parm t args k) k)
	 (insn:move dst var k)			      -> (begin (emit-move dst var (k/target k)) k)
	 (insn:fatbar lab jn k0 k1 k)		      -> (begin (emit-fatbar lab jn k0 k1 k) (cont:nil))
	 (insn:fail label npop free)		      -> (begin (emit-fail label npop free) (cont:nil))
	 (insn:nvcase tr dt tags jn alts ealt k)      -> (begin (emit-nvcase tr dt tags jn alts ealt k) (cont:nil))
	 (insn:pvcase tr tags arities jn alts ealt k) -> (begin (emit-pvcase tr tags arities jn alts ealt k) (cont:nil))
	 )))

    ;; XXX arrange to avoid duplicates caused by jump conts
    (define (declare-static name)
      (when (not (declared::member name))
	    (declared::add name)
	    (decls.write (format "static void " name "(void);"))))

    (define (move src dst)
      (if (and (>= dst 0) (not (= src dst)))
	  (o.write (format "O r" (int dst) " = r" (int src) ";"))))

    (define (emit-literal lit target)
      (let ((val (encode-immediate lit))
	    (prefix (if (= target -1)
			"// dead " ;; why bother with a dead literal?
			(format "O r" (int target)))))
	(o.write (format prefix " = (object *) " (int val) ";"))
	))

    (define (emit-litcon index kind target)
      (if (>= target 0)
	  (cond ((eq? kind 'string)
		 (o.write (format "O r" (int target) " = (object*) &constructed_" (int index) ";")))
		(else
		 (o.write (format "O r" (int target) " = (object *) constructed_" (int index) "[0];"))))))

    (define (emit-test reg jn k0 k1 k)
      (push-jump-continuation k jn)
      (o.write (format "if PXLL_IS_TRUE(r" (int reg)") {"))
      (o.indent)
      (emit k0)
      (o.dedent)
      (o.write "} else {")
      (o.indent)
      (emit k1)
      (o.dedent)
      (o.write "}")
      )

    (define (emit-testcexp args sig template jn k0 k1 k)
      ;; we know we're testing a cexp, just inline it here
      (match sig with
	(type:pred 'arrow (result-type . arg-types) _)
	-> (let ((args0 (map (lambda (reg) (format "r" (int reg))) args))
		 (args1 (map2 wrap-in arg-types args0))
		 (exp (wrap-out result-type (cexp-subst template args1))))
	     (push-jump-continuation k jn)
	     (o.write (format "if PXLL_IS_TRUE(" exp ") {"))
	     (o.indent)
	     (emit k0)
	     (o.dedent)
	     (o.write "} else {")
	     (o.indent)
	     (emit k1)
	     (o.dedent)
	     (o.write "}"))
	_ -> (impossible)))

    (define (emit-jump reg target jump-num free)
      (move reg target)
      (let ((jname (format "JUMP_" (int jump-num))))
	(match (used-jumps::get jump-num) with
	  (maybe:yes free)
	  -> (o.write (format jname "(" (join (lambda (x) (format "r" (int x))) ", " free) ");"))
	  (maybe:no)
	  -> (impossible))
	))

    ;; XXX consider this: giving access to the set of free registers.
    ;;   would make it possible to do %ensure-heap in a %%cexp.
    (define (emit-cexp sig type template args target)
      (let ((exp
	     (match sig with
	       (type:pred 'arrow (result-type . arg-types) _)
	       -> (let ((args0 (map (lambda (reg) (format "r" (int reg))) args))
			(args1 (map2 wrap-in arg-types args0)))
		    ;; from the sig
		    ;;(wrap-out result-type (cexp-subst template args1))
		    ;; the solved type
		    (wrap-out type (cexp-subst template args1))
		    )
	       ;; some constant type
	       _ -> (wrap-out sig template))))
	(if (= target -1)
	    (o.write (format exp ";"))
	    (o.write (format "O r" (int target) " = " exp ";")))))

    (define (emit-check-heap free size)
      (let ((n (length free)))
	(o.write (format "if (freep + " size " >= limit) {"))
	(o.indent)
	;; copy free variables into tospace
	(for-range
	    i n
	    (o.write (format "heap1[" (int (+ i 3)) "] = r" (int (nth free i)) ";")))
	;; gc
	(o.write (format "gc_flip (" (int n) ");"))
	;; copy values back into free variables
	(for-range
	    i n
	    (o.write (format "r" (int (nth free i)) " = heap0[" (int (+ i 3)) "];")))
	(o.dedent)
	(o.write "}")
	))

    (define (emit-close name nreg body target)
      (let ((cname (gen-function-cname name 0)))
	(declare-static cname)
	(PUSH fun-stack
	      (lambda ()
		(set! current-function-name name)
		(set! current-function-cname cname)
		(o.write (format "static void " cname " (void) {"))
		(o.indent)
		(if (vars-get-flag name (node/varref name) VFLAG-ALLOCATES)
		    ;; XXX this only works because we disabled letreg around functions
		    (emit-check-heap '() "0"))
		(emit body)
		(o.dedent)
		(o.write "}")))
	(o.write (format "O r" (int target) " = allocate (TC_CLOSURE, 2);"))
	(o.write (format "r" (int target) "[1] = " cname "; r" (int target) "[2] = lenv;"))
	))

    (define (push-continuation cname insn args)
      (let ((args (format (join (lambda (x) (format "O r" (int x))) ", " args))))
	(PUSH fun-stack
	      (lambda ()
		(o.write (format "static void " cname "(" args ") {"))
		(o.indent)
		(emit insn)
		(o.dedent)
		(o.write "}")
		))))

    (define (push-fail-continuation insn jump args)
      (push-continuation (format "FAIL_" (int jump)) insn args))

    (define (push-jump-continuation cont jump)
      (match (used-jumps::get jump) with
	(maybe:yes free)
	-> (let ((cname (format "JUMP_" (int jump))))
	     (decls.write (format "static void " cname "(" (string-join (n-of (length free) "O") ", ") ");"))
	     (push-continuation (format "JUMP_" (int jump)) (k/insn cont) free)
	     )
	(maybe:no)
	-> #u))

    (define (emit-varref d i target)
      (if (>= target 0)
	  (let ((src
		 (if (= d -1)
		     (format "top[" (int (+ 2 i)) "];") ;; the +2 is to skip the header and next ptr
		     ;;(format "varref (lenv, " (int d) ", " (int i) ");")
		     (format "((object*" (repeat d "*") ") lenv) " (repeat d "[1]") "[" (int (+ i 2)) "];")
		     )))
	    (o.write (format "O r" (int target) " = " src)))))

    (define (emit-varset d i v target)
      (if (= d -1)
	  (o.write (format "top[" (int (+ 2 i)) "] = r" (int v) ";"))
	  ;;(o.write (format "varset (lenv, " (int d) ", " (int i) ", r" (int v) ");"))
	  (o.write (format "((object*" (repeat d "*") ") lenv) " (repeat d "[1]") "[" (int (+ i 2)) "] = r" (int v) ";"))
	  )
      (when (> target 0)
	    ;; this handles this idiom:
	    ;; (let ((x 3)
	    ;;       (_ (set! x 99))
	    ;;       (y ...)) ...)
	    ;; the set! is a dead assignment, but we need to put something there
	    (o.write (format "O r" (int target) " = (object *) TC_UNDEFINED;"))))

    (define (emit-new-env size top? types target)
      (let ((env-index (env-counter.inc)))
	(o.write (format "// env " (int env-index) ":"))
	(o.write (format "//   " (join type-repr " " types)))
	(o.write (format "O r" (int target) " = allocate (TC_ENV, " (int (+ size 1)) ");"))
	(if top?
	    (o.write (format "top = r" (int target) ";")))))

    (define (emit-alloc tag size target)
      (let ((tag-string
	     (match tag with
	       (tag:bare v) -> (format (int v))
	       (tag:uobj v) -> (format (if (= size 0) "UITAG(" "UOTAG(") (int v) ")"))))
	(if (= size 0)
	    ;; unit type - use an immediate
	    (o.write (format "O r" (int target) " = (object*)" tag-string ";"))
	    (o.write (format "O r" (int target) " = allocate (" tag-string ", " (int size) ");")))))

    (define (emit-store off arg tup i)
      (o.write (format "r" (int tup) "[" (int (+ 1 (+ i off))) "] = r" (int arg) ";")))

    (define (emit-tail name fun args)
      (let ((funcall
	     (match name with
	       (maybe:no)       -> (format "((kfun)(r" (int fun) "[1]))();")
	       (maybe:yes name) -> (let ((cname (gen-function-cname name 0)))
				     (declare-static cname)
				     (format cname "();")))))
	(if (>= args 0)
	    (o.write (format "r" (int args) "[1] = r" (int fun) "[2]; lenv = r" (int args) "; " funcall))
	    (o.write (format "lenv = r" (int fun) "[2]; " funcall))
	    )))

    (define (emit-call name fun args k)
      (let ((free (sort < (k/free k))) ;; sorting these might improve things
	    (nregs (length free))
	    (target (k/target k))
	    (kfun (gen-function-cname current-function-name (current-function-part.inc)))
	    )
	;; save
	(o.write (format "O t = allocate (TC_SAVE, " (int (+ 3 nregs)) ");"))
	(let ((saves
	       (map-range
		   i nregs
		   (format "t[" (int (+ i 4)) "] = r" (int (nth free i))))))
	  (declare-static kfun)
	  (o.write (format "t[1] = k; t[2] = lenv; t[3] = " kfun "; " (string-join saves "; ") "; k = t;")))
	;; call
	(let ((funcall
	       (match name with
		 (maybe:no)	  -> (format "((kfun)(r" (int fun) "[1]))();") ;;; unknown
		 (maybe:yes name) -> (let ((cfun (gen-function-cname name 0))) ;;; known
				       ;; include last-minute forward declaration
				       (declare-static cfun)
				       (format cfun "();")
				       ))))
	  (if (>= args 0)
	      (o.write (format "r" (int args) "[1] = r" (int fun) "[2]; lenv = r" (int args) "; " funcall))
	      (o.write (format "lenv = r" (int fun) "[2]; " funcall))))
	;; emit a new c function to represent the continuation of the current irken function
	(PUSH fun-stack
	      (lambda ()
		(set! current-function-cname kfun)
		(o.write (format "static void " kfun " (void) {"))
		(o.indent)
		;; restore
		(let ((restores
		       (map-range
			   i nregs
			   (format "O r" (int (nth free i)) " = k[" (int (+ i 4)) "]"))))
		  (o.write (format (string-join restores "; ") "; lenv = k[2]; k = k[1];")))
		(if (>= target 0)
		    (o.write (format "O r" (int target) " = result;")))
		(emitk k)
		(o.dedent)
		(o.write (format "}"))
		)
	      )
	))

    (define (emit-trcall depth name regs)
      (let ((nargs (length regs))
	    (npop (- depth 1))
	    (cname (gen-function-cname name 0)))
	(if (= nargs 0)
	    ;; a zero-arg trcall needs an extra level of pop
	    (set! npop (+ npop 1)))
	(if (> npop 0)
	    (o.write (format "lenv = ((object " (joins (n-of npop "*")) ")lenv)" (joins (n-of npop "[1]")) ";")))
	(for-range
	    i nargs
	    (o.write (format "lenv[" (int (+ 2 i)) "] = r" (int (nth regs i)) ";")))
	(declare-static cname)
	(o.write (format cname "();"))
      ))

    (define (emit-push args)
      (o.write (format "r" (int args) "[1] = lenv; lenv = r" (int args) ";")))

    (define (emit-pop src target)
      (o.write (format "lenv = lenv[1];"))
      (move src target))

    (define (subset? a b)
      (every? (lambda (x) (member-eq? x b)) a))

    (define (guess-record-type sig)
      ;; can we disambiguate this record signature?
      (let ((sig (map (lambda (x) ;; remove sexp wrapping
			(match x with
			  (sexp:symbol field) -> field
			  _ -> (impossible))) sig))
	    (sig (filter (lambda (x) (not (eq? x '...))) sig)))
	(let ((candidates '()))
	  (for-each
	   (lambda (x)
	     (match x with
	       (:pair sig0 index0)
	       -> (if (subset? sig sig0)
		      (PUSH candidates sig0))))
	   the-context.records)
	  (if (= 1 (length candidates))
	      ;; unambiguous - there's only one possible match.
	      (maybe:yes (nth candidates 0))
	      ;; this sig is ambiguous given the set of known records.
	      (maybe:no)))))

    ;; hacks for datatypes known by the runtime
    (define (get-uotag dtname altname index)
      (match dtname altname with
	'list 'cons -> "TC_PAIR"
	'symbol 't -> "TC_SYMBOL"
	_ _ -> (format "UOTAG(" (int index) ")")))

    (define (get-uitag dtname altname index)
      (match dtname altname with
	'list 'nil -> "TC_NIL"
	'bool 'true -> "(pxll_int)PXLL_TRUE"
	'bool 'false -> "(pxll_int)PXLL_FALSE"
	_ _ -> (format "UITAG(" (int index) ")")))

    (define (emit-primop name parm type args k)

      (define (primop-error)
	(error1 "primop" name))

      (let ((target (k/target k))
	    (nargs (length args)))
	;; these need to be broken up into separate functions...
	(match name with
	  '%dtcon  -> (match parm with
			(sexp:cons dtname altname)
			-> (match (alist/lookup the-context.datatypes dtname) with
			     (maybe:no) -> (error1 "emit-primop: no such datatype" dtname)
			     (maybe:yes dt)
			     -> (let ((alt (dt.get altname)))
				  (cond ((= nargs 0)
					 (o.write (format "O r" (int target) " = (object*)" (get-uitag dtname altname alt.index) ";")))
					(else
					 (if (>= target 0)
					     (let ((trg (format "r" (int target))))
					       (o.write (format "O " trg " = alloc_no_clear (" (get-uotag dtname altname alt.index) "," (int nargs) ");"))
					       (for-range
						   i nargs
						   (o.write (format trg "[" (int (+ i 1)) "] = r" (int (nth args i)) ";"))))
					     (warning (format "dead target in primop " (sym name) "\n"))
					     )))))
			_ -> (primop-error)
			)
	  '%nvget   -> (match parm args with
			 (sexp:list (_ (sexp:int index) _)) (reg)
			 -> (o.write (format "O r" (int target) " = UOBJ_GET(r" (int reg) "," (int index) ");"))
			 _ _ -> (primop-error))
	  '%make-vector -> (match args with
			     (vlen vval)
			     -> (begin
				  ;; since we cannot know the size at compile-time, there should
				  ;; always be a call to ensure_heap() before any call to %make-vector
				  (o.write (format "O r" (int target) ";"))
				  (o.write (format "if (unbox(r" (int vlen) ") == 0) { r" (int target) " = (object *) TC_EMPTY_VECTOR; } else {"))
				  (o.write (format "  O t = alloc_no_clear (TC_VECTOR, unbox(r" (int vlen) "));"))
				  (o.write (format "  for (int i=0; i<unbox(r" (int vlen) "); i++) { t[i+1] = r" (int vval) "; }"))
				  (o.write (format "  r" (int target) " = t;"))
				  (o.write "}"))
			     _ -> (primop-error))
	  '%array-ref -> (match args with
			   (vec index)
			   -> (begin
				(o.write (format "range_check (GET_TUPLE_LENGTH(*(object*)r" (int vec) "), unbox(r" (int index)"));"))
				(o.write (format "O r" (int target) " = ((pxll_vector*)r" (int vec) ")->val[unbox(r" (int index) ")];")))
			   _ -> (primop-error))
	  '%array-set -> (match args with
			   (vec index val)
			   -> (begin
				(o.write (format "range_check (GET_TUPLE_LENGTH(*(object*)r" (int vec) "), unbox(r" (int index)"));"))
				(o.write (format "((pxll_vector*)r" (int vec) ")->val[unbox(r" (int index) ")] = r" (int val) ";"))
				(when (> target 0)
				      (o.write (format "O r" (int target) " = (object *) TC_UNDEFINED;"))))
			   _ -> (primop-error))
	  '%record-get -> (match parm args with
			    (sexp:list ((sexp:symbol label) (sexp:list sig))) (rec-reg)
			    -> (let ((label-code (lookup-label-code label)))
				 (match (guess-record-type sig) with
				   (maybe:yes sig0)
				   -> (o.write (format "O r" (int target) ;; compile-time lookup
						       " = ((pxll_vector*)r" (int rec-reg)
						       ")->val[" (int (index-eq label sig0))
						       "];"))
				   (maybe:no)
				   -> (o.write (format "O r" (int target) ;; run-time lookup
						       " = ((pxll_vector*)r" (int rec-reg)
						       ")->val[lookup_field((GET_TYPECODE(*r" (int rec-reg)
						       ")-TC_USEROBJ)>>2," (int label-code)
						       ")];"))))
			    _ _ -> (primop-error))
	  ;; XXX very similar to record-get, maybe some way to collapse the code?
	  '%record-set -> (match parm args with
			    (sexp:list ((sexp:symbol label) (sexp:list sig))) (rec-reg arg-reg)
			    -> (let ((label-code (lookup-label-code label)))
				 (match (guess-record-type sig) with
				   (maybe:yes sig0)
				   -> (o.write (format "((pxll_vector*)r" (int rec-reg) ;; compile-time lookup
						       ")->val[" (int (index-eq label sig0))
						       "] = r" (int arg-reg) ";"))
				   (maybe:no)
				   -> (o.write (format "((pxll_vector*)r" (int rec-reg) ;; run-time lookup
						       ")->val[lookup_field((GET_TYPECODE(*r" (int rec-reg)
						       ")-TC_USEROBJ)>>2," (int label-code)
						       ")] = r" (int arg-reg) ";")))
				 (when (> target 0)
				       (o.write (format "O r" (int target) " = (object *) TC_UNDEFINED;"))))
			    _ _ -> (primop-error))
	  '%ensure-heap -> (emit-check-heap (k/free k) (format "unbox(r" (int (car args)) ")"))
	  '%callocate -> (let ((type (parse-type parm))) ;; gets parsed twice, convert to %%cexp?
			   ;; XXX maybe make alloc_no_clear do an ensure_heap itself?
			   (if (>= target 0)
			       (o.write (format "O r" (int target) " = alloc_no_clear (TC_BUFFER, HOW_MANY (sizeof (" (irken-type->c-type type)
						") * unbox(r" (int (car args)) "), sizeof (object)));"))
			       (error1 "%callocate: dead target?" type)))
	  '%exit -> (begin
		      (o.write (format "result=r" (int (car args)) "; exit_continuation();"))
		      (when (> target 0)
			    (o.write (format "O r" (int target) " = (object *) TC_UNDEFINED;"))))
	  '%cget -> (match args with
		      (rbase rindex)
		      ;; XXX range-check (probably need to add a length param to TC_BUFFER)
		      -> (let ((cexp (format "(((" (type-repr type) "*)((pxll_int*)r" (int rbase) ")+1)[" (int rindex) "])")))
			   (o.write (format "O r" (int target) " = " (wrap-out type cexp) ";")))
		      _ -> (primop-error))
	  '%cset -> (match args type with
		      (rbase rindex rval) (type:pred 'arrow (to-type from-type) _)
		      ;; XXX range-check (probably need to add a length param to TC_BUFFER)
		      -> (let ((rval-exp (lookup-cast to-type from-type (format "r" (int rval))))
			       (lval (format "(((" (type-repr to-type) "*)((pxll_int*)r" (int rbase) ")+1)[" (int rindex) "])")))
			   (o.write (format lval " = " rval-exp ";"))
			   (when (> target 0)
				 (o.write (format "O r" (int target) " = (object *) TC_UNDEFINED;"))))
		      _ _ -> (primop-error))
	  '%getcc -> (match args with
		       () -> (o.write (format "O r" (int target) " = k; // %getcc"))
		       _  -> (primop-error))
	  '%putcc -> (match args with
		       (rk rv) -> (begin
				    (o.write (format "k = r" (int rk) "; // %putcc"))
				    (move rv target))
		       _ -> (primop-error))
	  _ -> (primop-error))))

    (define (lookup-cast to-type from-type exp)
      (match to-type from-type with
	(type:pred tout _ _) (type:pred 'int _ _)
	-> (if (member-eq? tout c-int-types)
	       (format "((" (sym tout) ")unbox(" exp "))")
	       (error1 "lookup-cast: can't cast from int to: " tout))
	_ _ -> (error1 "lookup-cast: unable to cast between types: " (:pair to-type from-type))))

    (define (emit-move var src target)
      (cond ((and (>= src 0) (not (= src var)))
	     ;; from varset
	     (o.write (format "r" (int var) " = r" (int src) "; // reg varset"))
	     (if (>= target 0)
		 (o.write (format "O r" (int target) " = (object *) TC_UNDEFINED;"))))
	    ((and (>= target 0) (not (= target var)))
	     ;; from varref
	     (o.write (format "O r" (int target) " = r" (int var) "; // reg varref")))))

    ;; we emit insns for k0, which may or may not jump to fail continuation in k1
    (define (emit-fatbar label jn k0 k1 k)
      (fatbar-free::add label (k/free k))
      (push-fail-continuation k1 label (k/free k))
      (push-jump-continuation k jn)
      (o.write (format "// fatbar jn=" (int jn) " label=" (int label)))
      (emit k0))

    (define (emit-fail label npop free)
      (if (> npop 0)
	  (o.write (format "lenv = ((object " (joins (n-of npop "*")) ")lenv)" (joins (n-of npop "[1]")) ";")))
      (let ((jname (format "FAIL_" (int label))))
	(match (fatbar-free::get label) with
	  (maybe:yes free)
	  -> (begin
	       (o.write (format jname "(" (join (lambda (x) (format "r" (int x))) ", " free) ");"))
	       (decls.write (format "static void " jname "(" (string-join (n-of (length free) "O") ", ") ");")))
	  (maybe:no)
	  -> (impossible)
	  )))

    ;;
    ;; thinking about get_case():
    ;;
    ;;  We can avoid even more branching and checking of pointers by choosing the test function
    ;;  *after* deciding on where to put the 'default' fall-through.  For example, if we are testing
    ;;  a list, then the switch usually looks like this:
    ;;
    ;;  switch () {
    ;;  case TC_NIL:
    ;;     ...
    ;;  default:
    ;;     ...
    ;;  }
    ;;
    ;; So in this particular case we need only check for immediate TC_NIL.
    ;; XXX Before implementing, see if the C compiler isn't already doing this for us.
    ;;
    (define (which-typecode-fun dt) "get_case") ;; XXX

    (define (emit-nvcase test dtname tags jump-num subs ealt k)
      (let ((use-else? (maybe? ealt)))
	(match (alist/lookup the-context.datatypes dtname) with
	  (maybe:no) -> (error1 "emit-nvcase" dtname)
	  (maybe:yes dt)
	  -> ;;(if (and (= (length subs) 1) (= (dt.get-nalts) 1))
		 ;; (begin
		 ;;   ;; nothing to switch on, just emit the code
		 ;;   (printf "unused jump-num: " (int jump-num) "\n")
		 ;;   (emit (nth subs 0))
		 ;;   (emitk k) ;; and continue...
		 ;;   )
		 (let ((get-typecode (which-typecode-fun dt)))
		   (push-jump-continuation k jump-num)
		   (o.write (format "switch (" get-typecode " (r" (int test) ")) {"))
		   ;; XXX reorder tags to put immediate tests first!
		   (for-range
		       i (length tags)
		       (let ((label (nth tags i))
			     (sub (nth subs i))
			     (alt (dt.get label))
			     (arity alt.arity)
			     (uimm #f)
			     (tag (if (= arity 0) ;; immediate/unit constructor
				      (get-uitag dtname label alt.index)
				      (get-uotag dtname label alt.index))))
			 (o.indent)
			 (if (and (not use-else?) (= i (- (length tags) 1)))
			     (o.write "default: {")
			     (o.write (format "case (" tag "): {")))
			 (o.indent)
			 (emit sub)
			 (o.dedent)
			 (o.write "} break;")
			 (o.dedent)
			 ))
		   (match ealt with
		     (maybe:yes ealt0)
		     -> (begin
			  (o.indent)
			  (o.write "default: {")
			  (o.indent)
			  (emit ealt0)
			  (o.dedent)
			  (o.write "}")
			  (o.dedent))
		     _ -> #u)
		   (o.write "}")))))

    (define (emit-pvcase test-reg tags arities jump-num alts ealt k)
      (o.write (format "switch (get_case_noint (r" (int test-reg) ")) {"))
      (let ((else? (maybe? ealt))
	    (n (length alts)))
	(push-jump-continuation k jump-num)
	(for-range
	    i n
	    (let ((label (nth tags i))
		  (arity (nth arities i))
		  (alt (nth alts i))
		  (tag0 (match (alist/lookup the-context.variant-labels label) with
			  (maybe:yes v) -> v
			  (maybe:no) -> (error1 "variant constructor never called" label)))
		  (tag1 (format (if (= arity 0) "UITAG(" "UOTAG(") (int tag0) ")"))
		  (case0 (format "case (" tag1 "): {"))
		  (case1 (if (and (not else?) (= i (- n 1))) "default: {" case0)))
	      (o.indent)
	      (o.write case1)
	      (o.indent)
	      (emit alt)
	      (o.dedent)
	      (o.write "} break;")
	      (o.dedent)))
	(match ealt with
	  (maybe:yes ealt)
	  -> (begin
	       (o.indent)
	       (o.write (format "default: {"))
	       (o.indent)
	       (emit ealt)
	       (o.dedent)
	       (o.write "};")
	       (o.dedent))
	  (maybe:no) -> #u)
	(o.write "}")))

    ;; emit the top-level insns
    (o.write "static void toplevel (void) {")
    (o.indent)
    (emit insns)
    (o.dedent)
    (o.write "}")
    ;; now emit all function defns
    (let loop ()
      (match fun-stack with
	() -> #u
	_  -> (begin ((pop fun-stack)) (loop))
	))
    ))

(define (emit-profile-0 o)
  (o.write "
static int64_t prof_mark0;
static int64_t prof_mark1;
typedef struct {
  int calls;
  int64_t ticks;
  char * name;
} pxll_prof;
static pxll_prof prof_funs[];
static int prof_current_fun;
static int prof_num_funs;
static prof_dump (void)
{
 int i=0;
 fprintf (stderr, \"%20s\\t%20s\\t%s\\n\", \"calls\", \"ticks\", \"name\");
 for (i=0; prof_funs[i].name; i++) {
   fprintf (stderr, \"%20d\\t%20\" PRIu64 \"\\t%s\\n\", prof_funs[i].calls, prof_funs[i].ticks, prof_funs[i].name);
 }
}
"))

(define (emit-profile-1 o)
  (o.write "static pxll_prof prof_funs[] = \n  {{0, 0, \"top\"},")
  (for-each
   (lambda (names)
     (let ((name (cdr (reverse names)))) ;; strip 'top' off
       (o.write (format "   {0, 0, \"" (join symbol->string "." name) "\"},"))))
   the-context.profile-funs)
  (o.write "   {0, 0, NULL}};"))

;; we support three types of non-immediate literals:
;;
;; 1) strings.  identical strings are *not* merged, since
;;      modifying strings is a reasonable choice.
;; 2) symbols.  this emits a string followed by a symbol tuple.
;;      these are collected so each is unique.  any runtime
;;      symbol table should be populated with these first.
;; 3) constructed.  trees of literals made of constructors
;;      (e.g. lists formed with QUOTE), and vectors.  each tree
;;      is rendered into a single C array where the first value
;;      in the array points to the beginning of the top-level
;;      object.

(define (emit-constructed o)
  (let ((lits (reverse the-context.literals))
	(nlits (length lits))
	(strings (alist/make))
	(output '())
	(current-index 0)
	(symbol-counter 0)
	)

    ;; emit UOHEAD and UITAG macros, special-casing the builtin datatypes
    (define (uohead nargs dt variant index)
      (match dt variant with
	'list 'cons -> "CONS_HEADER"
	_ _ -> (format "UOHEAD(" (int nargs) "," (int index) ")")))

    (define (uitag dt variant index)
      (match dt variant with
	'list 'nil -> "TC_NIL"
	_ _ -> (format "UITAG(" (int index) ")")))

    (define (walk exp)
      (match exp with
	;; data constructor
	(literal:cons dt variant args)
	-> (let ((dto (alist/get the-context.datatypes dt "no such datatype"))
		 (alt (dto.get variant))
		 (nargs (length args)))
	     (if (> nargs 0)
		 ;; constructor with args
		 (let ((args0 (map walk args))
		       (addr (+ 1 (length output))))
		   (PUSH output (uohead nargs dt variant alt.index))
		   (for-each (lambda (x) (PUSH output x)) args0)
		   (format "UPTR(" (int current-index) "," (int addr) ")"))
		 ;; nullary constructor - immediate
		 (uitag dt variant alt.index)))
	(literal:vector args)
	-> (let ((args0 (map walk args))
		 (nargs (length args))
		 (addr (+ 1 (length output))))
	     (PUSH output (format "(" (int nargs) "<<8)|TC_VECTOR"))
	     (for-each (lambda (x) (PUSH output x)) args0)
	     (format "UPTR(" (int current-index) "," (int addr) ")"))
	(literal:symbol sym)
	-> (let ((index (alist/get the-context.symbols sym "unknown symbol?")))
	     (format "UPTR(" (int index) ",1)"))
	(literal:string s)
	-> (match (alist/lookup strings s) with
	     (maybe:yes index) -> (format "UPTR0(" (int index) ")")
	     (maybe:no) -> (error "emit-constructed: lost string"))
	_ -> (int->string (encode-immediate exp))
	))
    (o.dedent) ;; XXX fix this by defaulting to zero indent
    (for-range
	i nlits
	(set! output '())
	(set! current-index i)
	(let ((lit (nth lits i)))
	  (match lit with
	    ;; strings are a special case here because they have a non-uniform structure: the existence of
	    ;;   the uint32_t <length> field means it's hard for us to put a UPTR in the front.
	    (literal:string s)
	    -> (let ((slen (string-length s)))
		 ;; this works because we want strings compared for eq? identity...
		 (alist/push strings s i)
		 (o.write (format "pxll_string constructed_" (int i) " = {STRING_HEADER(" (int slen) "), " (int slen) ", \"" (c-string s) "\" };")))
	    ;; there's a temptation to skip the extra pointer at the front, but that would require additional smarts
	    ;;   in insn_constructed (as already exist for strings).
	    ;; NOTE: this reference to the string object only works because it comes before the symbol in the-context.constructed.
	    (literal:symbol s)
	    -> (begin
		 (o.write (format "// symbol " (sym s)))
		 (o.write (format "pxll_int constructed_" (int i)
				  "[] = {UPTR(" (int i)
				  ",1), SYMBOL_HEADER, UPTR0(" (int (- current-index 1))
				  "), INTCON(" (int symbol-counter) ")};"))
		 (set! symbol-counter (+ 1 symbol-counter))
		 )
	    _ -> (let ((val (walk (nth lits i)))
		       (rout (list:cons val (reverse output))))
		   (o.write (format "pxll_int constructed_" (int i) "[] = {" (join id "," rout) "};")))
	    )))
    (let ((symptrs '()))
      (alist/iterate
       (lambda (symbol index)
	 (PUSH symptrs (format "UPTR(" (int index) ",1)")))
       the-context.symbols)
      (o.write (format "pxll_int pxll_internal_symbols[] = {(" (int (length symptrs)) "<<8)|TC_VECTOR, " (join id ", " symptrs) "};"))
      )
    (o.indent)
    ))

(define c-string-safe?
  (char-class
   (string->list
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ ")))

;; fix when we get zero-padding format capability...
(define (char->oct-encoding ch)
  (let ((in-oct (format (oct (char->ascii ch)))))
    (format
     (match (string-length in-oct) with
       0 -> "000"
       1 -> "00"
       2 -> "0"
       _ -> (error1 "unable to oct-encode character" ch)
       )
     in-oct)))

(define (c-string s)
  (let loop ((r '())
	     (s (string->list s)))
    (match s with
      () -> (string-concat (reverse r))
      (ch . rest)
      -> (loop
	  (list:cons
	   (match ch with
	     #\return  -> "\\r"
	     #\newline -> "\\n"
	     #\tab     -> "\\t"
	     #\\       -> "\\\\"
	     #\"       -> "\\\""
	     _ -> (if (c-string-safe? ch)
		      (char->string ch)
		      (char->oct-encoding ch)))
	   r)
	  rest))))

(define (emit-lookup-field o)
  (when (> (length the-context.records) 0)
	(o.write "static int lookup_field (int tag, int label)")
	(o.write "{ switch (tag) {")
	(for-each
	 (lambda (pair)
	   (match pair with
		  (:pair sig index)
	      -> (begin (o.write (format "  // {" (join symbol->string " " sig) "}"))
			(o.write (format "  case " (int index) ":"))
			(o.write "  switch (label) {")
			(for-range
			 i (length sig)
			 (o.write (format "     case "
					  (int (lookup-label-code (nth sig i)))
					  ": return " (int i) "; break;")))
			(o.write "  } break;"))))
	 (reverse the-context.records))
	(o.write "} return 0; }")))

(define (emit-datatype-table o)
  (o.write (format "// datatype table"))
  (alist/iterate
   (lambda (name dt)
     (o.write (format "// name: " (sym name)))
     (dt.iterate
      (lambda (tag alt)
	(o.write (format "//  (:" (sym tag) " " (join type-repr " " alt.types) ")")))))
   the-context.datatypes))
