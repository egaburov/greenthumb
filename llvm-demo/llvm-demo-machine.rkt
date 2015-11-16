#lang racket

(require "../machine.rkt" "../ast.rkt")

(provide llvm-demo-machine% (all-defined-out))

(define llvm-demo-machine%
  (class machine%
    (super-new)
    (inherit-field bit random-input-bit config
                   inst-id nop-id
                   ;; required fileds for stochastic and enumerative only
		   classes)
    (inherit get-class-id filter-live state-eq?)
    (override set-config get-state
              ;; required functions for stochastic and enumerative only
              reset-arg-ranges get-arg-ranges ;;analyze-args
	      update-live update-live-backward
              get-constructor
              )

    (define (get-constructor) llvm-demo-machine%)
    
    (unless bit (set! bit 32))
    (set! random-input-bit bit)
    (set! nop-id 0)
    (set! inst-id '#(nop 
                     and or xor add sub
                     and# or# xor# add# sub#
                     ;;_and _or _xor _add 
		     _sub
		     shl lshr ashr
		     shl# lshr# ashr#
		     _shl _lshr _ashr
                     ctlz
                     ))

    (define vars 5)
    (define var-range #f)
    (define const-range #f)
    (define bit-range #f)

    (when config 
	  (set! vars config)
          (reset-arg-ranges))
    
    (define (set-config x) 
      (set! config x) 
      (set! vars config)
      (reset-arg-ranges))

    ;; Generate program state from function init.
    ;; Our program state is a vector storing values of variables.
    (define (get-state init [extra #f])
      (for/vector ([i vars]) (init)))

    ;;;;;;;;;;;;;;;;;;;;; For stochastic and enumerative ;;;;;;;;;;;;;;;;;;

    ;; Instruction classes
    (set! classes 
          (vector '(and or xor add sub shl lshr ashr) ;; rrr
        	  '(and# or# xor# add# sub#) ;; rri
        	  '(shl# lshr# ashr#) ;;rri
        	  '(_sub _shl _lshr _ashr) ;;rir (commutative: _and _or _xor _add)
                  ))
	  
    ;; Set valid operands' ranges.
    (define (reset-arg-ranges)
      (set! var-range (list->vector (range vars)))
      (set! const-range (vector 0 1 -1 -2 -8))
      (set! bit-range (vector 0 1)))
    
    (define/public (get-arg-types opcode-name)
      (define class-id (get-class-id opcode-name))
      (cond
       [(equal? class-id 0) (vector `var-o `var-i `var-i)]
       [(equal? class-id 1) (vector `var-o `var-i `const)]
       [(equal? class-id 2) (vector `var-o `var-i `bit)]
       [(equal? class-id 3) (vector `var-o `const `var-i)]
       [(equal? opcode-name `ctlz) (vector `var-o `var-i)]
       [else (vector)]))

    ;; Get valid operands' ranges given opcode-name, live-in, live-out, and mode.
    ;; opcode-name: symbol
    ;; live-in & live-out: compact format
    ;; There are 3 modes.
    ;;  1) `basic (no restriction)
    ;;  2) `no-args = ignore reigster operands. Return `reg-o, `reg-i, and `reg-io for operand that is input register, output register, and input/output register respectively.
    (define (get-arg-ranges opcode-name entry live-in
                            #:live-out [live-out #f] #:mode [mode `basic])
      (define var-i
        (if live-in
            (filter-live var-range live-in)
            var-range))
      (define var-o
        (if live-out
            (filter-live var-range live-out)
            var-range))

      (for/vector 
       ([type (get-arg-types opcode-name)])
       (if (equal? mode `basic)
           (cond
            [(equal? type `var-o)  var-o]
            [(equal? type `var-i)  var-i]
            [(equal? type `const)  const-range]
            [(equal? type `bit)    bit-range])
           (cond
            [(equal? type `var-o)  `var-o]
            [(equal? type `var-i)  `var-i]
            [(equal? type `const)  const-range]
            [(equal? type `bit)    bit-range]))))

    (define (update-live live x)
      (define op (inst-op x))
      (if (= op nop-id)
          live
          (let ([new-live (vector-copy live)])
            (vector-set! new-live (vector-ref (inst-args x) 0) #t)
            new-live)))

    ;; For enumerative search
    (define (update-live-backward live x)
      (define new-live (vector-copy live))
      (define opcode-name (vector-ref inst-id (inst-op x)))
      (define args (inst-args x))
      (define args-type (get-arg-types opcode-name))
      (for ([arg args]
            [type args-type])
           (cond
            ;; kill first
            [(equal? type `var-o) (vector-set! new-live arg #f)]
            [(equal? type `var-i) (vector-set! new-live arg #t)]))
      new-live)

    ))
      