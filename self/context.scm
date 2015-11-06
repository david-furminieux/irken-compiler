;; -*- Mode: Irken -*-

(define (getenv-or var default)
  (let ((val (getenv var)))
    (if (= 0 (string-length val))
	default
	val)))

(define (make-options)
  {verbose		= #f
   nocompile		= #f
   extra-cflags		= ""
   optimize		= #f
   trace		= #f
   debugmacroexpansion	= #f
   profile		= #f
   noinline		= #f
   noletreg		= #f
   debugtyping          = #f
   quiet                = #f
   include-dirs		= (LIST "." (getenv-or "IRKENLIB" "/usr/local/lib/irken/"))
   })

(define (make-context)
  {datatypes            = (alist/make)
    aliases             = (alist/make)
    macros              = (alist/make)
    dep-graph           = (map-maker symbol-index<?)
    scc-graph           = '()
    vars                = (tree/empty)
    funs                = (tree/empty)
    regalloc            = (make-register-allocator)
    standard-macros     = "lib/derived.scm"
    cincludes           = '()
    lincludes           = '()
    cverbatim           = '()
    records             = '()
    labels              = '()
    literals            = '()
    literal-ids         = (tree/empty)
    symbols             = (alist/make)
    variant-labels      = (alist/make)
    options             = (make-options)
    exceptions          = (alist/make)
    profile-funs        = '()
    }
  )

;; XXX a builtin flags object would be nice...

(define (vars-get-var name exp)
  (match (tree/member the-context.vars symbol-index<? name) with
    (maybe:yes v) -> v
    (maybe:no) -> (begin (pp-node exp) (error1 "vars-get-var: no such var" name))))

(define (vars-get-flag name exp flag)
  (let ((var (vars-get-var name exp)))
    (bit-get var.flags flag)))

(define (vars-set-flag! name exp flag)
  (let ((var (vars-get-var name exp)))
    (set! var.flags (bit-set var.flags flag))))

;; XXX currently unused
(define (vars-inc-calls! name exp flag)
  (let ((var (vars-get-var name exp)))
    (set! var.calls (+ 1 var.calls))))

(define VFLAG-RECURSIVE 0) ;; function that is recursive
(define VFLAG-ESCAPES   1) ;; function/variable that escapes
(define VFLAG-FUNCTION  2) ;; variable is a function
(define VFLAG-ALLOCATES 3) ;; function that allocates
(define VFLAG-FREE      4) ;; function that accesses free variables
(define VFLAG-GETCC     5) ;; function uses getcc or putcc (consider calling this NOINLINE)
(define VFLAG-REG       6) ;; variable was put into a register
(define VFLAG-FREEREF   7) ;; variable is referenced free
(define VFLAG-NFLAGS    8)

;; urgh, needs to be an object
(define (add-var name)
  (match (tree/member the-context.vars symbol-index<? name) with
    (maybe:no) -> (set! the-context.vars
			(tree/insert the-context.vars
				     symbol-index<? name {flags=0 calls=0 refs=0 sets=0 mult=0}))
    ;; <fix> then <function>, shows up twice, ignore.
    (maybe:yes _) -> #u))

(define (add-vars root)

  (define (add name)
    (add-var name))

  (define (search exp)
    (match exp.t with
      ;; only these three bind names.
      (node:fix names)		   -> (for-each add names)
      (node:let names)		   -> (for-each add names)
      (node:function name formals) -> (begin (for-each add formals)
					     (add name))
      _ -> #u)
    (for-each search exp.subs))

  (search root)
  )

(define (build-vars root)
  (add-vars root)
  (add-var 'top))

(define (lookup-label-code label)
  (let loop ((pairs the-context.labels))
    (match pairs with
      () -> (error1 "lookup-label-code" label)
      ((:pair key val) . rest)
      -> (if (eq? key label)
	     val
	     (loop rest)))))

(define (print-vars)
  (let ((flagpad (+ 2 VFLAG-NFLAGS)))
    (print-string "vars = {\n")
    (print-string
     (format "  " (cpad  6 "refs") (cpad  6 "sets") (cpad 6 "calls")
	     (cpad 6 "mult") (lpad flagpad "flags") "  " (rpad 30 "name") "\n"))
    (tree/inorder
     (lambda (k v)
       (print-string
	(format "  "
		(lpad 6 (int v.refs))
		(lpad 6 (int v.sets))
		(lpad 6 (int v.calls))
		(lpad 6 (int v.mult))
		(lpad flagpad (flags-repr v.flags))
		"  "
		(rpad 30 (sym k))
		"\n")))
     the-context.vars)
    (print-string "}\n")))

