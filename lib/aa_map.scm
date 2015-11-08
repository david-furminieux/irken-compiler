;; -*- Mode: Irken -*-

;; http://eternallyconfuzzled.com/tuts/datastructures/jsw_tut_andersson.aspx
;; http://en.wikipedia.org/wiki/AA_tree

;; this code is based on the C examples given by Julienne, and as such isn't
;;   very representative of an Irken/ML style.  I'd like to make a pure functional
;;   implementation, and if possible make skew & split tail-recursive by making
;;   them work from the bottom up rather than top down.  [another approach would be
;;   to just adapt Julienne's non-recursive code].

;; I'm bothered by the fact that this uses an entire extra word to hold the
;;   level data.  *theoretically*, it should be possible to write these
;;   algorithms without it (i.e., one bit per node for color), yet I wonder
;;   if they could be kept as simple.

;; Note: as it stands, this code is pure as long as you don't use delete.
;;   however it is rare that one needs both deletion and purity, so feel free
;;   to use the 'pure' subset of this data structure thus.

(typealias rtree {level=int key='a val='b left=rtree right=rtree})

(define (node/make level key val left right) : (int 'a 'b rtree rtree -> rtree)
  { level = level
    key   = key
    val   = val
    left  = left
    right = right })

(define tree/nil
  (let ((node (node/make 0 (magic #u) (magic #u) (magic #u) (magic #u))))
    (set! node.left node)
    (set! node.right node)
    node))

(define (tree/empty) : ( -> rtree)
  tree/nil)

(define (tree/skew d) : (rtree -> rtree)
  (if (and (> d.level 0)
	   (= d.left.level d.level))
      (node/make
       d.level d.left.key d.left.val d.left.left
       (node/make
	d.level d.key d.val d.left.right
	(tree/skew d.right)))
      d))

(define (tree/split b) : (rtree -> rtree)
  (if (and (= b.right.right.level b.level)
	   (not (= b.level 0)))
      (node/make
       (+ 1 b.level) b.right.key b.right.val
       (node/make b.level b.key b.val b.left b.right.left)
       (tree/split b.right.right))
      b))

;; urghhh, probably should have put '<' as the last arg.
(define (tree/insert root < key val) : (rtree ('a 'a -> bool) 'a 'b -> rtree)
  (let loop ((n root))
    (if (= n.level 0)
	(node/make 1 key val tree/nil tree/nil)
	(tree/split
	 (tree/skew
	  (if (< key n.key)
	      (node/make n.level n.key n.val (loop n.left) n.right)
	      (node/make n.level n.key n.val n.left (loop n.right)))
	  )))))

(defmacro tree/insert!
  (tree/insert! root < key val)
  -> (set! root (tree/insert root < key val)))

(defmacro tree/delete!
  (tree/delete! root key < =)
  -> (set! root (tree/delete root key < =)))

;; XXX make this pure.

(define (tree/delete root key key-less? key-equal?) : (rtree 'a ('a 'a -> bool) ('a 'a -> bool) -> rtree)
  (let recur ((root root) (key key))
    (if (not (eq? root tree/nil))
	(if (key-equal? key root.key)
	    (if (and (not (eq? root.left tree/nil))
		     (not (eq? root.right tree/nil)))
		(let loop ((heir root.left))
		  (cond ((not (eq? heir.right tree/nil))
			 (loop heir.right))
			(else
			 (set! root.key heir.key)
			 (set! root.val heir.val)
			 (set! root.left (recur root.left root.key)))))
		(set! root (if (eq? root.left tree/nil) root.right root.left)))
	    (if (key-less? root.key key)
		(set! root.right (recur root.right key))
		(set! root.left (recur root.left key))
		)))
    (if (or (< root.left.level (- root.level 1))
	    (< root.right.level (- root.level 1)))
	(begin
	  (set! root.level (- root.level 1))
	  (if (> root.right.level root.level)
	      (set! root.right.level root.level))
	  (tree/skew (tree/split root)))
	root
	)))

(define (tree/member root < key) : (rtree ('a 'a -> bool) 'a -> (maybe 'b))
  (let member0 ((t root))
    (cond ((= t.level 0) (maybe:no))
	  ((< key t.key) (member0 t.left))
	  ((< t.key key) (member0 t.right))
	  (else (maybe:yes t.val)))))

(define (tree/inorder p t) : (('a 'b -> undefined) rtree -> undefined)
  (let recur ((t t))
    (cond ((= t.level 0) #u)
	  (else
	   (recur t.left)
	   (p t.key t.val)
	   (recur t.right)))))

(define (tree/reverse p t) : (('a 'b -> undefined) rtree -> undefined)
  (let recur ((t t))
    (cond ((= t.level 0) #u)
	  (else
	   (recur t.right)
	   (p t.key t.val)
	   (recur t.left)))))

(define (tree/keys t) : (rtree -> (list 'a))
  (let ((r '()))
    (tree/reverse (lambda (k v) (PUSH r k)) t)
    r))

(define (tree/values t) : (rtree -> (list 'b))
  (let ((r '()))
    (tree/reverse (lambda (k v) (PUSH r v)) t)
    r))

(define (tree/dump d p t) : (int ('a 'b -> undefined) rtree -> undefined)
  (let recur ((d d) (t t))
    (if (= t.level 0)
	#u
	(begin
	  (recur (+ d 1) t.left)
	  (p t.key t.val d)
	  (recur (+ d 1) t.right)))))

;; the defn of make-generator, call/cc, etc... makes it pretty hard
;;  to pass more than one arg through a continuation.  so instead we'll
;;  use a 'pair' constructor to iterate through the tree...

(define (tree/make-generator tree)
  (make-generator
   (lambda (consumer)
     (tree/inorder
      (lambda (k v)
	(consumer (maybe:yes (:pair k v))))
      tree)
     (forever (consumer (maybe:no))))
   ))
