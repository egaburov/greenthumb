#lang racket

(require "../machine.rkt")

(provide arm-machine% (all-defined-out))

(struct progstate (regs memory))
(struct progstate+ progstate (extra))

(define-syntax-rule (build-vector n init)
  (let ([vec (make-vector n)])
    (for ([i (in-range n)])
	 (vector-set! vec i (init)))
    vec))

;; Macros to create init state for testing
(define-syntax default-state
  (syntax-rules (reg mem)
    ((default-state machine init)
     (progstate (build-vector (send machine get-nregs) init) 
                (build-vector (send machine get-nmems) init)))
    ((default-state machine init [reg (a b) ...] [mem (c d) ...])
     (let ([state (default-state machine init)])
       (vector-set! (progstate-regs state) a b)
       ...
       (vector-set! (progstate-memory state) c d)
       ...
       state))
    ((default-state [reg valr] [mem valm])
     (progstate valr valm))
    ((default-state [mem valm] [reg valr])
     (progstate valr valm))))

(define (lam-t) #t)
(define (lam-f) #f)

;; Macros to create output state constraint
(define-syntax constraint
  (syntax-rules (all none reg mem mem-all)
    ((constraint machine all) (default-state machine lam-t))

    ((constraint machine none) (default-state machine lam-f))

    ((constraint machine [reg r ...] [mem-all])
     (let ([state (default-state machine lam-f [reg (r #t) ...] [mem])])
       (struct-copy progstate state 
                    [memory (make-vector (send machine get-nmems) #t)]))
     )

    ((constraint machine [reg r ...] [mem m ...])
     (default-state machine lam-f [reg (r #t) ...] [mem (m #t) ...]))

    ((constraint [mem m ...] [reg r ...])
     (constraint [reg r ...] [mem m ...]))

    ((constraint [reg r ...] [mem m ...])
     (default-state lam-f [reg (r #t) ...] [mem (m #t) ...]))
    ))

(define arm-machine%
  (class machine%
    (super-new)
    (inherit-field bit random-input-bit inst-id classes classes-len perline)
    (inherit print-line)
    (override set-config get-config set-config-string
              adjust-config config-exceed-limit?
              get-state display-state
              output-constraint-string
              display-state-text parse-state-text
              progstate->vector vector->progstate)

    (set! bit 32)
    (set! random-input-bit 32)
    (set! inst-id '#(nop 
                     add sub rsb
                     add# sub# rsb#
                     and orr eor bic orn
                     and# orr# eor# bic# orn#
                     mov mvn
                     mov# mvn# movw# movt#
                     rev rev16 revsh rbit
                     asr lsl lsr
                     asr# lsl# lsr#
                     sdiv udiv
                     mul mla mls
                     ;;smmul smmla smmls
                     bfc bfi
                     sbfx ubfx
                     clz
                     ldr str
                     ldr# str#
                     tst cmp
                     tst# cmp#
                     ))

    ;; Instruction classes
    (set! classes 
          (vector '(add sub rsb
			and orr eor bic orn
			asr lsl lsr
			sdiv udiv mul
			ldr str) ;; rrr
		  '(add# sub# rsb#
			 and# orr# eor# bic# orn#
			 ldr# str#) ;; rri
		  '(asr# lsl# lsr#) ;; rri
		  '(mov mvn 
			rev rev16 revsh rbit
			clz
                        tst cmp) ;;rr
		  '(mov# mvn# movw# movt# tst# cmp#) ;; ri
		  '(mla mls) ;; rrrr
		  '(bfi sbfx ubfx) ;; rrii
		  ;'(bfc) ;; rii
                  ))

;; In ARM instructions, constant can have any value that can be produced by rotating an 8-bit value right by any even number of bits within a 32-bit word.

    (set! classes-len (vector-length classes))
    (set! perline 8)

    (init-field [branch-inst-id '#(beq bne j jal b jr jr jalr bal)]
                [shf-inst-id '#(nop asr lsl lsr asr# lsl# lsr#)]
		[inst-with-shf '(add sub rsb
				     and orr eor bic orn mov mvn)])

    (define nregs 5)
    (define nmems 1)

    (define/public (get-nregs) nregs)
    (define/public (get-nmems) nmems)
    (define/public (get-shf-inst-id x)
      (vector-member x shf-inst-id))
    (define/public (get-shf-inst-name x)
      (vector-ref shf-inst-id x))

    (define (get-config)
      (list nregs nmems))

    ;; info: (list nregs nmem)
    (define (set-config info)
      (set! nregs (first info))
      (set! nmems (second info))
      )

    ;; info: (list nregs nmem)
    (define (set-config-string info)
      (format "(list ~a ~a)" 
              (first info) (second info)))


    (define (adjust-config info)
      ;; Double the memory size
      (list (first info) (* 2 (second info))))

    (define (config-exceed-limit? info)
      ;; Memory size > 1000
      (> (second info) 1000))

    ;; live-out: a list of live registers' ids, same format is the output of (select-code) and (combine-live-out)
    ;; output: output constraint corresponding to live-out in string. When executing, the expression is evaluated to a progstate with #t and #f indicating which entries are constrainted (live).
    (define (output-constraint-string machine-var live-out)
      (cond
       [(first live-out)
        (define live-regs-str (string-join (map number->string (first live-out))))
        (define live-mem (second live-out))
        (if live-mem
            (format "(constraint ~a [reg ~a] [mem-all])" machine-var live-regs-str)
            (format "(constraint ~a [reg ~a] [mem])" machine-var live-regs-str))]
       [else #f]))

    ;; live-out: a list of live registers' ids
    ;; output: a progstate object. #t elements indicate live.
    (define/public (output-constraint live-out)
      ;; Registers are default to be dead.
      (define regs (make-vector nregs #f))
      ;; Memory is default to be live.
      (define memory (if (second live-out)
                         (make-vector nmems #t)
                         (make-vector nmems #f)))
      (for ([x (first live-out)])
           (vector-set! regs x #t))
      (progstate regs memory))

    (define (get-state init extra)
      (default-state this init))

    ;; Pretty print functions
    (define (display-state s)
      (pretty-display "REGS:")
      (print-line (progstate-regs s))
      (pretty-display "MEMORY:")
      (print-line (progstate-memory s)))

    (define (no-assumption)
      #f)

    (define (display-state-text pair)
      (define state (cdr pair))
      (define regs (progstate-regs state))
      (define memory (progstate-memory state))
      (define regs-str (string-join (map number->string (vector->list regs))))
      (define memory-str (string-join (map number->string (vector->list memory))))
      (pretty-display (format "~a,~a" regs-str memory-str)))

    (define (parse-state-text str)
      (define tokens (string-split str ","))
      (define regs-str (first tokens))
      (define memory-str (last tokens))
      (define regs (list->vector (map string->number (string-split regs-str))))
      (define memory (list->vector (map string->number (string-split memory-str))))
      (cons #t (progstate regs memory)))

    (define (progstate->vector x)
      (vector (progstate-regs x) (progstate-memory x)))

    (define (vector->progstate x)
      (progstate (vector-ref x 0) (vector-ref x 1)))

    ))