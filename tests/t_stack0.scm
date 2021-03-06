;; -*- Mode: Irken -*-

;; test lib/stack.scm

(include "lib/core.scm")
(include "lib/pair.scm")
(include "lib/stack.scm")

(let ((s0 (make-stack))
      (s1 (make-stack))
      (s2 (make-stack))
      )
  (s0.push 3)
  (s0.push 4)
  (s1.push #t)
  (s1.push #f)
  (s0.push 5)
  (s0.push 6)
  (print (s0.pop))
  (printn (s0.get))
  (s2.push #\A)
  (printn (s0.length))
  (s2.push #\B)
  (printn (s2.pop))
  (printn (s2.pop))
  (printn (s1.get))
  (s1.pop)
  (s1.pop)
  (s1.pop)
  )
