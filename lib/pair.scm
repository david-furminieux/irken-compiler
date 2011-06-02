;; -*- Mode: Irken -*-

;; this needs to be renamed to 'list.scm'

(datatype list
  (:nil)
  (:cons 'a (list 'a))
  )

;; null?/cons/car/cdr aren't actually used that much in Irken code,
;;   since pattern matching is safer and easier to read.
(define null?
  () -> #t
  _  -> #f
  )

(define (cons a b)
  (list:cons a b))

(define car
  () -> (error "car")
  (x . _) -> x)

(define cdr
  () -> (error "cdr")
  (_ . y) -> y)

;; I'm planning on downcasing these two eventually.  I was thinking of
;;  such macros in C-like terms - i.e., warn the user that they're macros,
;;  but it just annoyingly sticks out.
(defmacro LIST
  (LIST)         -> (list:nil)
  (LIST x y ...) -> (list:cons x (LIST y ...)))

(defmacro PUSH
  (PUSH l v)     -> (set! l (list:cons v l))
  )

(defmacro pop
  (pop l) -> (match l with
	       (list:nil) -> (error "pop")
	       (list:cons hd tl) -> (begin (set! l tl) hd)))

(defmacro prepend
  (prepend l)	    -> l
  (prepend a b ...) -> (list:cons a (prepend b ...)))

;; http://groups.google.com/group/comp.lang.scheme/msg/0055f311d1e1ce08

(define reverse-onto
  () b	      -> b
  (hd . tl) b -> (reverse-onto tl (list:cons hd b)))

(define (reverse l)
  (reverse-onto l '()))

(define (append list1 list2)
  (reverse-onto (reverse list1) list2))

(define append1
  ()        x -> (list:cons x (list:nil))
  (hd . tl) x -> (list:cons hd (append1 tl x)))

(define (length l)
  (define fun
    () acc	  -> acc
    (hd . tl) acc -> (fun tl (+ 1 acc)))
  (fun l 0))

(define (first l) (car l))
(define (second l) (car (cdr l)))
(define last
  ()	   -> (error "last")
  (last)   -> last
  (_ . tl) -> (last tl))

;; A possible pattern-matching named-let construct?
;; (define (length l)
;;   (let loop (0 l)
;;     acc ()	  -> acc
;;     acc (hd . tl) -> (loop tl (+ 1 acc))))

;; this is different enough from the scheme <member> to warrant
;;   the new name.

(define member?
  x ()        = -> #f
  x (hd . tl) = -> (if (= hd x) #t (member? x tl =))
  )

;; XXX need to get inlining to work through this
(define member-eq?
  x ()	      -> #f
  x (hd . tl) -> (if (eq? x hd) #t (member-eq? x tl))
  )

(define remove-eq
  x () -> '()
  x (hd . tl) -> (if (eq? hd x)
		     tl
		     (list:cons hd (remove-eq x tl))))

(defmacro remove-eq!
  (remove! item list) -> (set! list (remove-eq item list))
  )

(define nth
  ()       _ -> (error "list index out of range")
  (hd . _) 0 -> hd
  (_ . tl) n -> (nth tl (- n 1))
  )

(define (index-eq v l)
  (let loop ((i 0)
	     (l l))
    (match l with
      ()	-> (error "list index out of range")
      (hd . tl) -> (if (eq? hd v)
		       i
		       (loop (+ i 1) tl)))))

;; needed: fancy pythonic slicing with negative index, slop, etc...
(define (slice l start end)
  (if (< (- end start) 0)
      '()
      (let loop ((l l) (i 0) (r '()))
	(cond ((< i start) (loop (cdr l) (+ i 1) r))
	      ((< i end) (loop (cdr l) (+ i 1) (list:cons (car l) r)))
	      (else (reverse r))))))

;; (range 5) => '(0 1 2 3 4)
(define (range n)
  (let loop ((n (- n 1))
	     (l (list:nil)))
    (if (< n 0)
	l
	(loop (- n 1) (cons n l)))))

(define (n-of n x)
  (let loop ((n n)
	     (l (list:nil)))
    (if (<= n 0)
	l
	(loop (- n 1) (cons x l)))))

(define map
  p () -> '()
  p (hd . tl) -> (list:cons (p hd) (map p tl)))

;; could we use a macro to define nary map?
(define map2
  p () ()		    -> '()
  p (hd0 . tl0) (hd1 . tl1) -> (list:cons (p hd0 hd1) (map2 p tl0 tl1))
  p a b			    -> (error1 "map2: unequal-length lists" (:pair a b))
  )

(defmacro map-range
  (map-range vname num body ...)
  -> (let (($n num))
       (let $loop ((vname 0)
		   ($acc (list:nil)))
	 (if (= vname $n)
	     (reverse $acc)
	     ($loop (+ vname 1) (list:cons (begin body ...) $acc))))))

(define filter
  p () -> '()
  p (hd . tl) -> (if (p hd)
		     (list:cons hd (filter p tl))
		     (filter p tl)))

;; it's a shame that for-each puts the procedure first,
;;   definitely hurts readability when using a lambda.
(define for-each
  p ()        -> #u
  p (hd . tl) -> (begin (p hd) (for-each p tl)))

(define for-each2
  p () ()		-> #u
  p (h0 . t0) (h1 . t1) -> (begin (p h0 h1) (for-each2 p t0 t1))
  p _ _			-> (error "for-each2: unequal-length lists")
  )

(define fold
  p acc ()	  -> acc
  p acc (hd . tl) -> (fold p (p hd acc) tl)
  )

(define foldr
  p acc ()	  -> acc
  p acc (hd . tl) -> (p hd (foldr p acc tl))
  )

(define some?
  p () -> #f
  p (hd . tl) -> (if (p hd) #t (some? p tl)))

(define every?
  p () -> #t
  p (hd . tl) -> (if (p hd) (every? p tl) #f))

(define every2?
  p () () -> #t
  p (h0 . t0) (h1 . t1) -> (if (p h0 h1) (every2? p t0 t1) #f)
  p _ _ -> (error "every2?: unequal-length lists")
  )

;; print a list with <proc>, and print <sep> between each item.
(define print-sep
  proc sep ()	     -> #u
  proc sep (one)     -> (proc one)
  proc sep (hd . tl) -> (begin (proc hd) (print-string sep) (print-sep proc sep tl)))

;; collect lists of duplicate runs
;; http://www.christiankissig.de/cms/files/ocaml99/problem09.ml
;; I put in the '(reverse s)' call to make the algorithm 'stable'.
(define (pack l =)
  (define (pack2 l s e)
    (match l with
      ()      -> (LIST (reverse s))
      (h . t) -> (if (= h e)
		     (pack2 t (list:cons h s) e)
		     (list:cons (reverse s) (pack2 t (LIST h) h)))))
  (match l with
    ()	    -> '()
    (h . t) -> (pack2 t (LIST h) h)))

(define (vector->list v)
  (let loop ((n (- (vector-length v) 1)) (acc (list:nil)))
    (if (< n 0)
	acc
	(loop (- n 1) (list:cons v[n] acc)))))

(define (list->vector l)
  (define recur
    v _ ()      -> v
    v n (x . y) -> (begin (set! v[n] x) (recur v (+ n 1) y)))
  (match l with
    ()       -> #()  ;; special-case test for empty list
    (x . _)  -> (let ((n (length l))
		      (v (make-vector n x)))
		  (recur v 0 l))))

;; ;; using %vec16-set because the type system keeps <recur>
;; ;;   generic, thus skipping the vec16 detection.  gotta figure this out.
;; (define (list->vec16 l)
;;   (define recur
;;     v _ ()      -> v
;;     v n (x . y) -> (begin (%vec16-set v n x) (recur v (+ n 1) y)))
;;   (match l with
;;     ()       -> #()  ;; special-case test for empty list
;;     (_ . _)  -> (let ((n (length l))
;; 		      (v (%make-vec16 n)))
;; 		  (recur v 0 l))))

;; http://www.codecodex.com/wiki/Merge_sort#OCaml

(define (sort < l)

  (define (merge la lb)
    (let loop ((la la) (lb lb))
      (match la lb with
	() lb -> lb
	;; implement optimize-nvcase to put this back
	;;la () -> la
	(_ . _) () -> la
	(ha . ta) (hb . tb)
	-> (if (< ha hb)
	       (list:cons ha (loop ta (list:cons hb tb)))
	       (list:cons hb (loop (list:cons ha ta) tb))
	       )
	)))

  (define (halve l)
    (match l with
      ()  -> (:pair l '())
      (x) -> (:pair l '())
      (hd . tl)
      -> (match (halve tl) with
	   (:pair t0 t1) -> (:pair (list:cons hd t1) t0))))
  
  (define (merge-sort l)
    (match l with
      ()   -> l
      (x)  -> l
      list -> (match (halve l) with
		(:pair l0 l1) -> (merge (merge-sort l0) (merge-sort l1)))))

  (merge-sort l)

  )
