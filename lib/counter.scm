;; -*- Mode: Irken -*-

(define (make-counter init)
  (let ((value init))

    (define (inc)
      (let ((r value))
	(set! value (+ 1 value))
	r))

    (define (get)
      value)

    {inc=inc get=get}
    ))
