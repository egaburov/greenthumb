#lang racket

(require "inst.rkt" "decomposer.rkt" "ops-racket.rkt" "enumerator.rkt")
(require racket/generator)

(provide forwardbackward% entry-live entry-flag)

(struct concat (collection inst))
(struct box (val))

(define-syntax-rule (entry live flag) (list live flag))
(define-syntax-rule (entry-live x) (first x))
(define-syntax-rule (entry-flag x) (second x))

(define forwardbackward%
  (class decomposer%
    (super-new)
    (inherit-field machine printer simulator validator stat syn-mode)
    (inherit window-size)
    (init-field inverse% enumerator% [enum #f])
    (override synthesize-window superoptimize-linear superoptimize-binary)
    (public try-cmp? combine-live prescreen sort-live sort-live-bw
            reduce-precision increase-precision
            reduce-precision-assume
            change-inst change-inst-list
            mask-in get-live-mask inst->vector extra-slots)
    
    (define debug #f)
    (define verbo #f)
    (define info #f)
    (define ce-limit 100)

    ;; Actual bitwidth
    (define bit-precise (get-field bitwidth machine))
    
    ;; Reduce bitwidth
    (define bit 4)
    (define mask (sub1 (arithmetic-shift 1 bit)))
    (define mask-1 (sub1 (arithmetic-shift 1 (sub1 bit))))

    (set! machine
          (new (send machine get-constructor) [bitwidth bit]
               [config (send machine get-config)]))
    (define simulator-abst
      (new (send simulator get-constructor) [machine machine]))
    (define validator-abst
      (new (send validator get-constructor) [machine machine]
           [simulator
            (new (send (get-field simulator validator) get-constructor)
                 [machine machine])]))
    (define inverse (new inverse% [machine machine] [simulator simulator-abst]))
    (set! enum (new enumerator% [machine machine] [printer printer]))
    
    ;;;;;;;;;;;;;;;;;;;;;;; Helper functions ;;;;;;;;;;;;;;;;;;;;;;
    (define (inst->vector x) (vector (inst-op x) (inst-args x)))
    (define (prescreen my-inst state-vec) #t)
    (define (extra-slots) 0)
    
    ;; Return a copy of a given instruction x,
    ;; but replacing each constant c in the instruction x with (change c).
    (define (change-inst x change)
      (define opcode-name (send machine get-opcode-name (inst-op x)))
      (define args (inst-args x))
      (define types (send machine get-arg-types opcode-name))
      
      (define new-args
        (for/vector
         ([arg args]
          [type types])
         (if (member type '(const bit bit-no-0 op2))
             (change arg type)
             arg)))

      (inst (inst-op x) new-args))

    ;; Return a list of copies of a given instruction x,
    ;; but replacing each constant c in the instruction x with
    ;; one of the values from (change c).
    ;; Because (change c) returns a list of values instead of a value,
    ;; this method has to return all possible unique copies of x.
    (define (change-inst-list x change)
      (define op (inst-op x))
      (define opcode-name (send machine get-opcode-name op))
      (define args (inst-args x))
      (define types (send machine get-arg-types opcode-name))
      
      (define new-args
        (for/list
         ([arg args]
          [type types])
         (if (member type '(const bit bit-no-0 op2))
             (change arg type)
             (list arg))))

      (for/list ([final-args (all-combination-list new-args)])
                (inst op (list->vector final-args))))

    ;; Heuristic to sort what programs to explore first.
    (define (sort-live x) x)
    (define (sort-live-bw x) x)
    (define (reduce-precision-assume x) x)
    (define (mask-in state live #:keep-flag [keep #t])
      (cond
       [(list? state)
        (for/list ([s state]
                   [l live])
                  (mask-in s l))]
       [(vector? state)
        (for/vector ([s state]
                     [l live])
                    (mask-in s l))]
       [(pair? state)
        (cons (mask-in (car state) (car live)) (mask-in (cdr state) (cdr live)))]
       [else (and live state)]))

    (define (get-live-mask state)
      (cond
       [(list? state) (for/list ([s state]) (get-live-mask s))]
       [(vector? state) (for/vector ([s state]) (get-live-mask s))]
       [(pair? state)
        (cons (get-live-mask (car state)) (get-live-mask (cdr state)))]
       [else (number? state)]))

    (define c-behaviors 0)
    (define c-progs 0)

    ;; Insert state-vec into forward equivlance classes.
    (define (class-insert! class live states-vec prog)
      (set! c-progs (add1 c-progs))

      (define (insert-inner x states-vec prog)
        (define key (car states-vec))
        (if (= (length states-vec) 1)
	    (if (hash-has-key? x key)
		(hash-set! x key (cons prog (hash-ref x key)))
		(begin
		  (set! c-behaviors (add1 c-behaviors))
		  (hash-set! x key (list prog))))
	    (let ([has-key (hash-has-key? x key)])
	      (unless has-key (hash-set! x key (make-hash)))
	      (insert-inner (hash-ref x key) (cdr states-vec) prog))))

      (define key (entry live (send enum get-flag (car states-vec))))
      (unless (hash-has-key? class key) (hash-set! class key (make-hash)))
      (insert-inner (hash-ref class key) states-vec prog))

    (define c-behaviors-bw 0)
    (define c-progs-bw 0)

    ;; Use IDs to represent programs and instructions to use less memory.
    (define instvec2id (make-hash))
    (define id2inst (make-vector 1000000 #f))
    (define last-id 0)

    (define prog2id (make-hash))
    (define id2prog (make-vector 10000000 #f))
    (define last-prog-id 1)

    (define (reset)
      (set! instvec2id (make-hash))
      (set! id2inst (make-vector 1000000 #f))
      (set! last-id 0)
      (set! prog2id (make-hash))
      (set! last-prog-id 1))

    (define (prog->id prog)
      (unless (hash-has-key? prog2id prog)
	      (hash-set! prog2id prog last-prog-id)
	      (vector-set! id2prog last-prog-id prog)
	      (set! c-progs-bw (add1 c-progs-bw))
	      (set! last-prog-id (add1 last-prog-id)))
      (hash-ref prog2id prog))

    (define (id->prog id) (vector-ref id2prog id))

    (define (inst->id my-inst)
      (define inst-vec (inst->vector my-inst))
      (unless (hash-has-key? instvec2id inst-vec)
	      (hash-set! instvec2id inst-vec last-id)
	      (vector-set! id2inst last-id my-inst)
	      (set! last-id (add1 last-id)))
      (hash-ref instvec2id inst-vec))

    (define (id->real-progs id)
      (for/vector ([x (vector-ref id2prog id)])
		  (vector-ref id2inst x)))

    (define (concat-progs inst-id prog-set)
      (for/set ([prog-id prog-set])
	       (prog->id (cons inst-id (id->prog prog-id)))))

    ;; Insert into backward equivlance classes.
    (define (class-insert-bw-inner! top-hash key-list progs)
      (let* ([first-key (car key-list)]
	     [flag (send enum get-flag first-key)]
	     [live-mask (get-live-mask first-key)])
        ;; (when debug
        ;;       (unless (equal? debug live-mask)
        ;;               (send printer print-syntax
        ;;                     (send printer decode
        ;;                           (vector (vector-ref progs-bw prog))))
        ;;               (raise (format "not-eq ~a ~a" debug live-mask))))
	(unless (hash-has-key? top-hash flag)
		(hash-set! top-hash flag (make-hash)))
	(define middle-hash (hash-ref top-hash flag))
	(unless (hash-has-key? middle-hash live-mask)
		(hash-set! middle-hash live-mask (make-hash)))
	(let ([my-hash (hash-ref middle-hash live-mask)])
	  (for ([key key-list])
	       (if (hash-has-key? my-hash key)
		   (hash-set! my-hash key (set-union (hash-ref my-hash key) progs))
		   (begin
		     (set! c-behaviors-bw (add1 c-behaviors-bw))
		     (hash-set! my-hash key progs)))))))
      

    (define (class-insert-bw! class live test key-list new-progs)
      ;; (pretty-display `(class-insert-bw! ,live ,test ,key-list ,new-progs))
      ;; (pretty-display `(before ,class))
      (define key live)
      
      ;(set! states-vec (map (lambda (x) (abstract x live-list identity)) states-vec))
      (unless (hash-has-key? class key) 
	      (hash-set! class key (make-vector ce-limit #f)))

      (define tests (hash-ref class key))
      (unless (vector-ref tests test) (vector-set! tests test (make-hash)))
      (class-insert-bw-inner! (vector-ref tests test) key-list new-progs)
      ;; (pretty-display `(after ,class))
      )

    (define (class-init-bw! class live test state-vec)
      (define key live)

      (unless (hash-has-key? class key)
	      (hash-set! class key (make-vector ce-limit #f)))

      (define tests (hash-ref class key))
      (define top-hash (make-hash))
      (define middle-hash (make-hash))
      (define my-hash (make-hash))

      (vector-set! tests test top-hash)
      (hash-set! top-hash (send enum get-flag state-vec) middle-hash)
      (hash-set! middle-hash (get-live-mask state-vec) my-hash)
      (hash-set! my-hash state-vec (set 0))

      (hash-set! prog2id (list) 0)
      (vector-set! id2prog 0 (list)))

    (define (class-ref-bw class live flag test)
      (vector-ref (hash-ref class live) test))
      
    ;; Count number of programs in x.
    (define (count-collection x)
      (cond
       [(concat? x) (count-collection (concat-collection x))]
       [(vector? x) 1]
       [(list? x) (foldl + 0 (map count-collection x))]
       [else (raise (format "count-collection: unimplemented for ~a" x))]))

    (define (collect-behaviors x)
      (cond
       [(list? x)  x]
       [(hash? x)
        (let ([ans (list)])
          (for ([val (hash-values x)])
               (set! ans (append (collect-behaviors val) ans)))
          ans)]
       [(box? x) (collect-behaviors (box-val x))]
       [else
        (raise (format "collect-behaviors: unimplemented for ~a" x))]
       ))
    
    (define (get-collection-iterator collection)
      (define ans (list))
      (define (loop x postfix)
        (cond
         [(concat? x)
          (loop (concat-collection x) (vector-append (vector (concat-inst x)) postfix))]
         [(vector? x) 
          (set! ans (cons (vector-append x postfix) ans))]
         [(list? x) 
          (if (empty? x)
              (set! ans (cons postfix ans))
              (for ([i x]) (loop i postfix)))]
         [(set? x) 
          (if (set-empty? x)
              (set! ans (cons postfix ans))
              (for ([i x]) (loop i postfix)))]

         ))
      (loop collection (vector))
      ans)

    (define (copy x)
      (define ret (make-hash))
      (for ([pair (hash->list x)])
           (let ([key (car pair)]
                 [val (cdr pair)])
             (if (list? val)
                 (hash-set! ret key val)
                 (hash-set! ret key (copy val)))))
      ret)

    (define-syntax-rule (intersect l s)
      (filter (lambda (x) (set-member? s x)) l))


    (define (try-cmp? code state live) 0)
    ;; Combine liveness from two sources
    ;; x is from using update-live from live-in. This does not work well for memory.
    ;; y is from using symbolic analyze from live-out.
    (define (combine-live x y) y)
    
    ;;;;;;;;;;;;;;;;;;;;;;; Reduce/Increase bitwidth ;;;;;;;;;;;;;;;;;;;;;;

    ;; Convert input program into reduced-bitwidth program by replacing constants.
    ;; output: a pair of (reduced-bitwidth program, replacement map*)
    ;;   *replacement map maps reduced-bitwidth constants to sets of actual constants.
    (define (reduce-precision prog)
      ;; TODO: common one
      (define mapping (make-hash))
      (define (change arg type)
        (define (inner)
          (cond
           [(member type '(op2 bit bit-no-0))
            (cond
             [(and (> arg 0) (<= arg (/ bit-precise 4)))
              (/ bit 4)]
             [(and (> arg (/ bit-precise 4)) (< arg (* 3 (/ bit-precise 4))))
              (/ bit 2)]
             [(and (>= arg (* 3 (/ bit-precise 4))) (< arg bit-precise))
              (* 3 (/ bit 4))]
             [(= arg bit-precise) bit]
             [(> arg 0) (bitwise-and arg mask-1)]
             [else (finitize (bitwise-and arg mask) bit)])]

           [(> arg 0) (bitwise-and arg mask-1)]
           [else (finitize (bitwise-and arg mask) bit)]))

        (define ret (inner))
        (if (hash-has-key? mapping ret)
            (let ([val (hash-ref mapping ret)])
              (unless (member arg val)
                      (hash-set! mapping ret (cons arg val))))
            (hash-set! mapping ret (list arg)))
        ret)
        
      (cons (for/vector ([x prog]) (change-inst x change)) mapping))
    
    ;; Convert reduced-bitwidth program into program in precise domain.
    ;; prog: reduced bitwidth program
    ;; mapping: replacement map returned from 'reduce-precision' function
    ;; output: a list of potential programs in precise domain
    (define (increase-precision prog mapping)
      (define (change arg type)
        (define (finalize x)
          (if (hash-has-key? mapping arg)
              (let ([val (hash-ref mapping arg)])
                (if (member x val) val (cons x val)))
              (if (= x -2)
                  (list -2 -8)
                  (list x))))
        
        (cond
         [(= arg bit) (finalize bit-precise)]
         [(= arg (sub1 bit)) (finalize (sub1 bit-precise))]
         [(= arg (/ bit 2)) (finalize (/ bit-precise 2))]
         [else (finalize arg)]))

      (define ret (list))
      (define (recurse lst final)
        (if (empty? lst)
            (set! ret (cons (list->vector final) ret))
            (for ([x (car lst)])
                 (recurse (cdr lst) (cons x final)))))
      
      (recurse (reverse (for/list ([x prog]) (change-inst-list x change)))
               (list))
      ret)


    ;;;;;;;;;;;;;;;;;;;;;;; Timing variables ;;;;;;;;;;;;;;;;;;;;;;
    (define t-build 0)
    (define t-build-inter 0)
    (define t-build-hash 0)
    (define t-mask 0)
    (define t-hash 0)
    (define t-intersect 0)
    (define t-interpret-0 0)
    (define t-interpret 0)
    (define t-extra 0)
    (define t-verify 0)
    (define c-build-hash 0)
    (define c-intersect 0)
    (define c-interpret-0 0)
    (define c-interpret 0)
    (define c-extra 0)
    (define c-check 0)

    (define t-refine 0)
    (define t-collect 0)
    (define t-check 0)

    (define start-time #f)
    
    ;;;;;;;;;;;;;;;;;;;;;;; Main functions ;;;;;;;;;;;;;;;;;;;;;;
    (define (superoptimize-binary spec constraint time-limit size [extra #f]
				  #:lower-bound [lower-bound 0]
                                  #:assume [assumption (send machine no-assumption)]
                                  #:prefix [prefix (vector)] #:postfix [postfix (vector)]
                                  #:hard-prefix [hard-prefix (vector)] 
                                  #:hard-postfix [hard-postfix (vector)]
                                  )
      (superoptimizer-common spec prefix postfix constraint time-limit size
                             extra assumption))

    (define (superoptimize-linear spec constraint time-limit size [extra #f]
			   #:assume [assumption (send machine no-assumption)]
                           #:prefix [prefix (vector)] #:postfix [postfix (vector)]
                           #:hard-prefix [hard-prefix (vector)]
                           #:hard-postfix [hard-postfix (vector)])
      (superoptimizer-common spec prefix postfix constraint time-limit size
                             extra assumption))

    (define (superoptimizer-common spec prefix postfix constraint time-limit size
                                   extra assumption)
      (define sketch (make-vector (vector-length spec)))

      (synthesize-window spec sketch prefix postfix constraint extra
                         (send simulator performance-cost spec) time-limit
                         #:assume assumption))

    (define (synthesize-window spec sketch prefix postfix constraint extra 
			       [cost #f] [time-limit 3600]
			       #:hard-prefix [hard-prefix (vector)] 
			       #:hard-postfix [hard-postfix (vector)]
			       #:assume [assumption (send machine no-assumption)])
      (set! start-time (current-seconds))
      (send machine reset-opcode-pool)
      (send machine analyze-opcode prefix spec postfix)
      (define init
        (car (send validator
                   generate-input-states 1 (vector-append prefix spec postfix)
                   assumption extra #:db #t)))
      (define state2
        (send simulator interpret
              (vector-append prefix spec) init))
      (define live2
        (send validator get-live-in postfix constraint extra))
      (define try-cmp-status (try-cmp? spec state2 live2))
      (when info (pretty-display `(status ,try-cmp-status)))

      (define out-program #f)
      (define (exec x)
        (when (vector? out-program)
              (set! cost (send simulator performance-cost out-program)))
        
        (define iterator
          (generator
           ()
           (synthesize spec sketch prefix postfix constraint extra cost
                       assumption x time-limit)))
        
        (define (loop best-p)
          (define p (iterator))
          (when info (pretty-display `(loop-get ,p)))

          (cond
           [(equal? p "timeout") (or best-p p)]
           [p (loop p)]
           [else best-p]))
        
        (define tmp (loop #f))
        (set! out-program
              (if (vector? tmp) tmp (or out-program tmp))))
      
      (cond
       [(= try-cmp-status 0) ;; don't try cmp
        (exec #f)]
       [(= try-cmp-status 1) ;; must try cmp
        (exec #t)]
       [(= try-cmp-status 2) ;; should try cmp
        (exec #f)
        (set! start-time (current-seconds))
        (exec #t)
        ])

      out-program
      )

    (define (synthesize spec sketch prefix postfix constraint extra cost
                        assumption
                        try-cmp time-limit)
      (collect-garbage)
      (define size-from sketch)
      (define size-to sketch)
      (when (vector? sketch)
            (let ([len (vector-length sketch)])
              (set! size-from 1)
              (set! size-to (min (+ len (extra-slots)) (window-size)))))
      
      (reset)
      (send machine reset-arg-ranges)
      (define spec-precise spec)
      (define prefix-precise prefix)
      (define postfix-precise postfix)
      (define assumption-precise assumption)
      (define abst2precise #f)

      (let ([tmp (reduce-precision spec)])
        (set! spec (car tmp))
        (set! abst2precise (cdr tmp)))
      (when info
            (pretty-display `(try-cmp ,try-cmp))
            (pretty-display `(abst2precise ,abst2precise)))
      
      (set! prefix (car (reduce-precision prefix)))
      (set! postfix (car (reduce-precision postfix)))
      ;; (pretty-display `(assume ,assumption))
      (set! assumption (reduce-precision-assume assumption))

      ;; (send machine display-state assumption-precise)
      ;; (newline)
      ;; (send machine display-state assumption)

      (display "[")
      (send printer print-syntax (send printer decode prefix))
      (pretty-display "]")
      (send printer print-syntax (send printer decode spec))
      (display "[")
      (send printer print-syntax (send printer decode postfix))
      (pretty-display "]")

      (define live3-vec (send machine progstate->vector constraint))
      (define live2 (send validator-abst get-live-in postfix constraint extra))
      (define live2-vec (send machine progstate->vector live2))
      (define live1 (send validator-abst get-live-in (vector-append spec postfix) constraint extra))
      (define live0 (send validator-abst get-live-in (vector-append prefix spec postfix) constraint extra))
      (define live0-list (send machine get-live-list live0))

      (define live1-list-alt live0-list)
      (for ([x prefix])
           (set! live1-list-alt (send machine update-live live1-list-alt x)))
      
      (send machine analyze-args prefix spec postfix
            live1-list-alt live2 #:vreg 0)

      ;; Convert live2 after analyze-args to filter some live-out regs
      ;; that do not involve in here.
      (define live1-list (send machine get-live-list live1))
      (define live2-list (send machine get-live-list live2))
      
      (set! live1-list (combine-live live1-list-alt live1-list))

      (define step-bw 0)
      (define step-fw 0)
      (define step-bw-max 3)
      
      (define ntests 2)
      (define inits
        (send validator-abst generate-input-states ntests (vector-append prefix spec postfix)
              assumption extra #:db #t))
      (define states1 
	(map (lambda (x) (send simulator-abst interpret prefix x)) inits))
      (define states2
	(map (lambda (x) (send simulator-abst interpret spec x)) states1))
      (define states1-vec 
	(map (lambda (x) (mask-in (send machine progstate->vector x) live1-list))
             states1))
      (define states2-vec 
	(map (lambda (x) (mask-in (send machine progstate->vector x) live2-list #:keep-flag try-cmp)) states2))

      (when info
            (pretty-display `(states1-vec ,states1-vec))
            (pretty-display `(states2-vec ,states2-vec))
            (pretty-display `(live2-vec ,live2-vec))
            (pretty-display `(live1-list ,live1-list))
            (pretty-display `(live2-list ,live2-list)))
      
      (define ce-in (make-vector ce-limit))
      (define ce-out (make-vector ce-limit))
      (define ce-in-vec (make-vector ce-limit))
      (define ce-out-vec (make-vector ce-limit))
      (define ce-count ntests)
      (define ce-count-extra ntests)

      (define ce-in-final (list))
      (define ce-out-vec-final (list))

      (for ([test ntests]
            [state2 states2]
	    [state2-vec states2-vec])
           (vector-set! ce-out test state2)
	   (vector-set! ce-out-vec test state2-vec))

      ;; Initialize forward and backward classes
      (define prev-classes (make-hash))
      (class-insert! prev-classes live1-list states1-vec (vector))
      (define classes (copy prev-classes))

      (define classes-bw (make-vector (add1 step-bw-max)))
      (define classes-bw-expand (make-vector (add1 step-bw-max) 0))
      (for ([step (add1 step-bw-max)])
	   (vector-set! classes-bw step (make-hash)))
      (for ([test ntests])
           (class-init-bw! (vector-ref classes-bw 0) live2-list test (vector-ref ce-out-vec test))
           )
      (vector-set! classes-bw-expand 0 ntests)
      
      (define (gen-inverse-behaviors iterator)
        (define p (iterator))
        (define my-inst (car p))
        (when my-inst
          ;;(send printer print-syntax (send printer decode my-inst))
          (send inverse gen-inverse-behavior my-inst)
          (gen-inverse-behaviors iterator)
          ))
      
      (gen-inverse-behaviors (send enum generate-inst #f #f #f #f 
				   #:no-args #t))

      (define (check-final p)
        (when debug
              (pretty-display (format "[5] check-final ~a" (length ce-in-final)))
              (send printer print-syntax (send printer decode p)))
        (define
          pass
          (for/and ([input ce-in-final]
                    [output-vec ce-out-vec-final])
                   (let* ([my-output 
			   (with-handlers*
			    ([exn? (lambda (e) #f)])
			    (send simulator interpret (vector-append p postfix-precise) input))]
			  [my-output-vec
			   (and my-output (send machine progstate->vector my-output))])
                     (and my-output (send machine state-eq? output-vec my-output-vec live3-vec)))))

        (define final-program (vector-append prefix-precise p postfix-precise))

        (when
         pass
         (define ce (send validator counterexample 
                          (vector-append prefix-precise spec-precise postfix-precise)
                          final-program
                          constraint extra #:assume assumption))

         (if ce
             (let* ([ce-input
                     (send simulator interpret prefix-precise ce)]
                    [ce-output
                     (send simulator interpret (vector-append spec-precise postfix-precise) ce-input)]
                    [ce-output-vec
                     (send machine progstate->vector ce-output)])
               (when debug
                     (pretty-display "[6] counterexample (precise)")
                     (send machine display-state ce-input)
                     (pretty-display `(ce-out-vec ,ce-output-vec)))
               (set! ce-in-final (cons ce-input ce-in-final))
               (set! ce-out-vec-final (cons ce-output-vec ce-out-vec-final))
               )
             (let ([final-cost
                    (send simulator performance-cost p)])
               (newline)
               (pretty-display "[7] FOUND!!!")
               (send printer print-syntax (send printer decode p))
               (newline)
               (pretty-display `(cost ,final-cost))
               (pretty-display `(ce-count ,ce-count-extra))
               (pretty-display `(ce-count-precise ,(length ce-in-final)))
	       ;;(pretty-display `(time ,(- (current-seconds) start-time)))
               (newline)

               ;; Print to file
               (send stat update-best-correct
                     final-program
                     (send simulator performance-cost final-program))
               (yield p)
               (unless (member syn-mode '(linear binary))
                       (yield #f))
               (set! cost final-cost)
               (set! start-time (current-seconds))

               (when (<= final-cost (vector-length p))
                     (when info (pretty-display "YIELD done early"))
                     (yield #f))
               )))
        )
      
      (define (check-eqv progs progs-bw my-inst my-ce-count)
        (set! c-check (add1 c-check))
        (define t00 (current-milliseconds))
          
        (define (inner-progs p)
          
          ;; (pretty-display "After renaming")
          (when debug
                (pretty-display "[2] all correct")
                (pretty-display `(ce-count-extra ,ce-count-extra))
                )
          (when (= ce-count-extra ce-limit)
                (raise "Too many counterexamples")
                )

          (cond
           [(empty? ce-in-final)
          
            (define ce (send validator-abst counterexample 
                             (vector-append prefix spec postfix)
                             (vector-append prefix p postfix)
                             constraint extra #:assume assumption))

            (if ce
                (let* ([ce-input (send simulator-abst interpret prefix ce)]
                       [ce-input-vec
                        (send machine progstate->vector ce-input)]
                       [ce-output
                        (send simulator-abst interpret spec ce-input)]
                       [ce-output-vec
                        (send machine progstate->vector ce-output)])
                  (when debug
                        (newline)
                        (pretty-display "[3] counterexample")
                        (pretty-display `(ce ,ce-count-extra ,ce-input-vec ,ce-output-vec)))
                  (vector-set! ce-in ce-count-extra ce-input)
                  (vector-set! ce-out ce-count-extra ce-output)
                  (vector-set! ce-in-vec ce-count-extra ce-input-vec)
                  (vector-set! ce-out-vec ce-count-extra (mask-in ce-output-vec live2-list #:keep-flag try-cmp))
                  (set! ce-count-extra (add1 ce-count-extra))
                  )
                (begin
                  (when debug
                        (pretty-display "[4] found")
                        (send printer print-syntax (send printer decode p)))
                  (for ([x (increase-precision p abst2precise)])
                       (check-final x))
                  ))]

           [else
            (when debug
                  (pretty-display "[4] found")
                  (send printer print-syntax (send printer decode p)))
            (for ([x (increase-precision p abst2precise)])
                 (check-final x))]))

        (define (inner-behaviors p)
          (define t0 (current-milliseconds))
          ;; (pretty-display `(inner-behaviors ,my-ce-count ,ce-count-extra))
	  ;; (send printer print-syntax (send printer decode p))
          
          (define
            pass
            (and
             (or (not cost) (< (send simulator-abst performance-cost p) cost))
             (for/and ([i (reverse (range my-ce-count ce-count-extra))])
                      (let* ([input (vector-ref ce-in i)]
                             [output-vec (vector-ref ce-out-vec i)]
                             [my-output 
                              (with-handlers*
                               ([exn? (lambda (e) #f)])
                               (send simulator-abst interpret p input))]
                             [my-output-vec (and my-output (send machine progstate->vector my-output))])
                        (and my-output
                             (send machine state-eq? output-vec my-output-vec live2-vec))))))
          
          (define t1 (current-milliseconds))
          (set! t-extra (+ t-extra (- t1 t0)))
          (set! c-extra (add1 c-extra))
          (when pass
                (inner-progs p)
                (define t2 (current-milliseconds))
                (set! t-verify (+ t-verify (- t2 t1))))

          )

        (define h1
          (if (= my-ce-count ntests)
              (get-collection-iterator progs)
              progs))

        (define h2
          (if (= my-ce-count ntests)
              (get-collection-iterator progs-bw)
              progs-bw))

        
        ;; (let ([x my-inst])
        ;;   (when (and (equal? `eor
        ;;                      (vector-ref (get-field opcodes machine) (inst-op x)))
        ;;              (equal? `nop 
        ;;                      (vector-ref (get-field shf-opcodes machine) 
        ;;                                  (inst-shfop x)))
        ;;              (equal? 0 (vector-ref (inst-args x) 0))
        ;;              (equal? 0 (vector-ref (inst-args x) 1))
        ;;              (equal? 1 (vector-ref (inst-args x) 2))
        ;;              )
        ;;         (newline)
        ;;         (pretty-display (format "CHECK-EQV ~a ~a" (length h1) (length h2)))))
        
        (define t11 (current-milliseconds))
        
        (for* ([p1 h1]
               [p2 h2])
              (inner-behaviors (vector-append p1 (vector my-inst) p2)))
        (define t22 (current-milliseconds))
        (set! t-collect (+ t-collect (- t11 t00)))
        (set! t-check (+ t-check (- t22 t11)))
        )

      (define (refine my-classes my-classes-bw my-inst my-live1 my-live2 my-flag1 my-flag2)
	(define t00 (current-milliseconds))
        (define cache (make-vector ce-limit))
	(for ([i ce-limit]) 
	     (vector-set! cache i (make-hash)))

        (define (outer my-classes candidates level)
	  ;; (when (= 1 (inst-op my-inst))
	  ;; 	(pretty-display `(outer ,level ,candidates)))
	  (define my-classes-bw-level (vector-ref my-classes-bw level))
	  (define cache-level (vector-ref cache level))
          (define real-hash my-classes)
                   
	  (when
	   (and (not my-classes-bw-level)
                (= level (vector-ref classes-bw-expand step-bw)))
	   (define t0 (current-milliseconds))
	   (build-hash-bw-all level)
	   (set! my-classes-bw-level 
		 (class-ref-bw (vector-ref classes-bw step-bw) my-live2 my-flag2 level))
	   (define t1 (current-milliseconds))
	   (set! t-build (+ t-build (- t1 t0)))
	   )
                         
          (define ce-out-level (vector-ref ce-out level))
          (when (and (list? real-hash) (hash? my-classes-bw-level))
	   ;;(and (list? real-hash) (> (count-collection real-hash) 1))
		;;(pretty-display `(build-fw ,level ,(count-collection real-hash) ,(hash? real-hash-bw)))
                ;; list of programs
                (define t0 (current-milliseconds))
                (set! real-hash (make-hash))
                (define input (vector-ref ce-in level))
                
                (define (loop iterator)
                  (define prog (and (not (empty? iterator)) (car iterator)))
                  (when 
                   prog
                   (let* ([s0 (current-milliseconds)]
                          [state
			   (with-handlers*
			    ([exn? (lambda (e) #f)])
                            (send simulator-abst interpret prog input ce-out-level))]
                          [state-vec (and state (send machine progstate->vector state))]
                          [s1 (current-milliseconds)])
                     (when
                      state-vec
                      (if (hash-has-key? real-hash state-vec)
                          (hash-set! real-hash state-vec
                                     (cons prog (hash-ref real-hash state-vec)))
                          (hash-set! real-hash state-vec (list prog))))
                     (let ([s2 (current-milliseconds)])
                       (set! t-build-inter (+ t-build-inter (- s1 s0)))
                       (set! t-build-hash (+ t-build-hash (- s2 s1)))
                       (set! c-build-hash (add1 c-build-hash))
                       )
                     )

                   (loop (cdr iterator))
                   ))

                (if (= level ntests)
                    (loop (get-collection-iterator my-classes))
                    (loop my-classes))
                (define t1 (current-milliseconds))
                (set! t-build (+ t-build (- t1 t0)))
                )

          
          (define (inner)
            (define t0 (current-milliseconds))
            (define inters-fw (hash-keys real-hash))
            (define t1 (current-milliseconds))
            (set! t-intersect (+ t-intersect (- t1 t0)))
            (set! c-intersect (add1 c-intersect))
	    ;; (when (= 1 (inst-op my-inst))
	    ;; 	  (pretty-display `(inner ,level ,(length inters-fw))))

            (for ([inter inters-fw])
              (let ([t0 (current-milliseconds)]
		    [out-vec #f])

		(if (and (> level 0) (hash-has-key? cache-level inter))
		    (set! out-vec (hash-ref cache-level inter))
		    (let* ([s1 (current-milliseconds)]
                           [pass (prescreen my-inst inter)]
                           [out
                            (and pass
                                 (with-handlers*
                                  ([exn? (lambda (e) #f)])
                                  (send simulator-abst interpret (vector my-inst)
                                        (send machine vector->progstate inter)
                                        ce-out-level)))]
                           [s2 (current-milliseconds)]
                           )
		      (set! out-vec (and out (mask-in (send machine progstate->vector out) my-live2)))
                      (set! t-interpret-0 (+ t-interpret-0 (- s2 s1)))
                      (set! c-interpret-0 (add1 c-interpret-0))
		      (hash-set! cache-level inter out-vec)))

		(let ([t1 (current-milliseconds)])
		  (set! t-interpret (+ t-interpret (- t1 t0)))
		  (set! c-interpret (add1 c-interpret))
                  )

		;; (pretty-display `(out-vec ,out-vec))

		(when 
		 out-vec
		 (let ([flag (send enum get-flag out-vec)]
                       [s0 (current-milliseconds)])
		   (when
		    (hash-has-key? my-classes-bw-level flag)
		    (let* ([pairs (hash->list (hash-ref my-classes-bw-level flag))]
			   [s1 (current-milliseconds)])
		      ;; (when (> (length pairs) 1)
                      ;;       (pretty-display `(debug ,level ,pairs))
		      ;;       (raise
		      ;;        (format "(length pairs) = ~a" (length pairs))))
		      ;;(set! t-hash (+ t-hash (- s1 s0)))
		      (for ([pair pairs])
			   (let* ([t0 (current-milliseconds)]
				  [live-mask (car pair)]
				  [classes (cdr pair)]
				  [out-vec-masked 
				   (if (or (and try-cmp (not (equal? live-mask my-live2)))
                                           (not my-live2))
				       (mask-in out-vec live-mask)
				       out-vec)]
				  [t1 (current-milliseconds)]
				  [has-key (and out-vec-masked
                                                (hash-has-key? classes out-vec-masked))]
				  [progs-set (and has-key (hash-ref classes out-vec-masked))]
				  [t2 (current-milliseconds)]
				  [new-candidates
				   (and progs-set
					(if (= level 0)
					    (set->list progs-set)
					    (intersect candidates progs-set)))]
				  [t3 (current-milliseconds)])
                             ;; (unless out-vec-masked
                             ;;         (pretty-display `(live-mask ,live-mask))
                             ;;         (pretty-display `(out-vec ,out-vec)))
			     ;; (pretty-display `(inner ,level ,inter ,out-vec-masked ,new-candidates))
			     (set! t-mask (+ t-mask (- t1 t0)))
			     (set! t-hash (+ t-hash (- t2 t1)))
			     (set! t-intersect (+ t-intersect (- t3 t2)))
			     
			     (when
			      (and new-candidates (not (empty? new-candidates)))
			      (if (= 1 (- ce-count level))
				  (begin
				    ;;(pretty-display `(check-eqv-leaf ,level ,ce-count))
				    (check-eqv (hash-ref real-hash inter)
					       (map id->real-progs new-candidates)
					       my-inst ce-count)
				    (set! ce-count ce-count-extra)
				    )
				  (let ([a (outer (hash-ref real-hash inter)
						  new-candidates
						  (add1 level))])
				    (hash-set! real-hash inter a)))))))
		    )))
		)))
            
          (cond
	   [(equal? my-classes-bw-level #f) real-hash]

           [(hash? real-hash)
            (inner)
            real-hash]

           [else
	    (pretty-display `(check-eqv-inter ,level ,real-hash ,candidates))
            (check-eqv (collect-behaviors real-hash)
		       (map id->real-progs candidates)
                       my-inst level)
	    (set! ce-count ce-count-extra)
            real-hash
            ]))
       
        (outer my-classes #f 0)
	(define t11 (current-milliseconds))
	(set! t-refine (+ t-refine (- t11 t00)))
        )


      (define (build-hash my-hash iterator) 
        ;; Call instruction generator
        (define inst-liveout-vreg (iterator))
        (define my-inst (first inst-liveout-vreg))
	(define my-liveout (second inst-liveout-vreg))

	;; (define my-inst 
	;;   (vector-ref (send printer encode 
	;; 		    (send parser ir-from-string "and r0, r1, r2"))
	;; 	      0))
	;; (define my-liveout (cons '(0 1 2) '(0)))

        (define cache (make-hash))
        (when 
         my-inst
         (when debug
               (send printer print-syntax-inst (send printer decode-inst my-inst))
               (pretty-display my-liveout))

         (define (recurse x states2-vec level)
           (define ce-out-level (vector-ref ce-out level))
           (if (list? x)
               (class-insert! classes my-liveout (reverse states2-vec) (concat x my-inst))
               (for ([pair (hash->list x)])
                    (let* ([state-vec (car pair)]
                           [val (cdr pair)]
                           [out 
                            (if (and (list? val) (hash-has-key? cache state-vec))
                                (hash-ref cache state-vec)
                                (let ([tmp
                                       (and
                                        (prescreen my-inst state-vec)
                                        (with-handlers*
                                         ([exn? (lambda (e) #f)])
                                         (send machine progstate->vector 
                                               (send simulator-abst interpret 
                                                     (vector my-inst)
                                                     (send machine vector->progstate state-vec)
                                                     ce-out-level)))
                                        )
                                       ])
                                  (when (list? val) (hash-set! cache state-vec tmp))
                                  tmp))
                            ])
                      (when out (recurse val (cons out states2-vec) (add1 level)))))))
         
         (recurse my-hash (list) 0)
         (build-hash my-hash iterator)
	 ))

      (define (build-hash-bw-all test)
        (define my-ce-out-vec (vector-ref ce-out-vec test))
        (define same #f)
        (for ([i test] #:break same)
             (when (equal? my-ce-out-vec (vector-ref ce-out-vec i))
                   (set! same i)))
	;; (newline)
	;; (pretty-display `(build-hash-bw-all ,test ,same))
        (when (= (vector-ref classes-bw-expand 0) test)
              (vector-set! classes-bw-expand 0 (add1 test))
              (class-init-bw! (vector-ref classes-bw 0)
                              live2-list test my-ce-out-vec)
              )
	(for ([step step-bw])
             (when
              (= (vector-ref classes-bw-expand (add1 step)) test)
              (vector-set! classes-bw-expand (add1 step) (add1 test))
              (if same
                  (let ([current (vector-ref classes-bw (add1 step))])
                    (for ([pair (hash->list current)])
                         (let ([live-list (car pair)]
                               [my-hash (cdr pair)])
                           (vector-set! my-hash test (vector-ref my-hash same)))))
                
                  (let ([prev (vector-ref classes-bw step)]
                        [current (vector-ref classes-bw (add1 step))])
                    ;; (newline)
                    ;; (pretty-display `(step-test ,step ,test))
                    (set! c-behaviors-bw 0)
                    (set! c-progs-bw 0)
                    (for ([pair (hash->list prev)])
                         (let* ([live-list (car pair)]
                                [my-hash (cdr pair)]
                                [flag (hash-keys (vector-ref my-hash 0))]
                                [iterator (send enum generate-inst 
                                                #f live-list #f flag
                                               #:try-cmp try-cmp)])
                           ;; (pretty-display `(live ,live-list 
                           ;;                        ,(hash-count (vector-ref my-hash test))
                           ;;                        ,(hash-count (car (hash-values (vector-ref my-hash test))))))
                           (build-hash-bw test current live-list my-hash iterator)
                           ))
                    (pretty-display `(behavior-bw ,test ,step ,c-behaviors-bw ,c-progs-bw ,(- (current-seconds) start-time)))))))
        )

      (define (build-hash-bw test current old-liveout my-hash iterator)
	(define my-hash-test (vector-ref my-hash test))
	(define (inner)
	  (define inst-liveout-vreg (iterator))
	  (define my-inst (first inst-liveout-vreg))
	  (define my-liveout (third inst-liveout-vreg))

	  ;; (define my-inst 
	  ;;   (vector-ref (send printer encode 
	  ;; 		    (send parser ir-from-string "add r1, r0, r2"))
	  ;; 	      0))
	  ;; (define my-liveout (cons (list 0 2) (list)))

	  (when my-inst
                (when debug
                      (send printer print-syntax-inst (send printer decode-inst my-inst))
                      (pretty-display `(live ,my-liveout)))
                (define inst-id (inst->id my-inst))
                ;; (define t-interpret 0)
                ;; (define t-hash 0)
                ;; (define c 0)
		(for* ([live2states (hash-values my-hash-test)]
                       [mapping (hash-values live2states)]
		       [pair (hash->list mapping)])
		      (let* ([out-vec (car pair)]
			     [progs (cdr pair)]
                             ;;[t0 (current-milliseconds)]
			     [in-vec (send inverse interpret-inst my-inst out-vec old-liveout)]
                             ;;[t1 (current-milliseconds)]
                             )
			;; (pretty-display `(test-live ,test ,my-liveout ,in-vec))
			(when (and in-vec (not (empty? in-vec)))
			      (class-insert-bw! current my-liveout test 
						in-vec (concat-progs inst-id progs)))
                        ;; (let ([t2 (current-milliseconds)])
                        ;;   (set! t-interpret (+ t-interpret (- t1 t0)))
                        ;;   (set! t-hash (+ t-hash (- t2 t1)))
                        ;;   (when (list? in-vec) (set! c (+ c (length in-vec))))
                        ;;   )
                        )
                      )
                ;; (pretty-display `(time ,t-interpret ,t-hash ,c))
		(inner)
		))
	(inner))


      (define middle 0)
      (define (refine-all hash1 live1 flag1 hash2 live2 flag2 iterator)
        (when (> (- (current-seconds) start-time) time-limit)
              (yield "timeout"))
	(define inst-liveout-vreg (iterator))
        (define my-inst (first inst-liveout-vreg))
	;; (define my-inst 
	;;   (vector-ref (send printer encode 
	;; 		    (send parser ir-from-string "and r2, r1, r2, lsr 1"))
	;; 	      0))
        (when 
         my-inst
         (when
          verbo
          (send printer print-syntax-inst (send printer decode-inst my-inst)))
         (set! middle (add1 middle))
         (define ttt (current-milliseconds))
         (refine hash1 hash2 my-inst live1 live2 flag1 flag2)
         (when 
          (and verbo (> (- (current-milliseconds) ttt) 500))
          (pretty-display (format "search ~a ~a = ~a + ~a + ~a | ~a\t(~a + ~a/~a)\t~a ~a ~a/~a\t[~a/~a]\t~a/~a\t~a/~a (~a) ~a" 
                                  (- (current-milliseconds) ttt) ce-count-extra
                                  t-refine t-collect t-check
                                  t-build t-build-inter t-build-hash c-build-hash
                                  t-mask t-hash t-intersect c-intersect
                                  t-interpret-0 c-interpret-0
                                  t-interpret c-interpret
                                  t-extra c-extra c-check
                                  t-verify
                                  )))
         (set! t-build 0) (set! t-build-inter 0) (set! t-build-hash 0) (set! t-mask 0) (set! t-hash 0) (set! t-intersect 0) (set! t-interpret-0 0) (set! t-interpret 0) (set! t-extra 0) (set! t-verify 0)
         (set! c-build-hash 0) (set! c-intersect 0) (set! c-interpret-0 0) (set! c-interpret 0) (set! c-extra 0) (set! c-check 0)
         (set! t-refine 0) (set! t-collect 0) (set! t-check 0)
         (refine-all hash1 live1 flag1 hash2 live2 flag2 iterator)
         ))


      (define (main-loop size)
        (when
         (>= size size-from)
         (pretty-display (format "\nSIZE = ~a" size))
         
         (define keys (hash-keys classes))
         (define keys-bw (hash-keys (vector-ref classes-bw step-bw)))
         ;; (for ([key keys])
         ;;      (pretty-display `(key ,(entry-live key) ,(entry-flag key))))
         (set! keys (sort-live keys))
         (set! keys-bw (sort-live-bw keys-bw))

         ;; (pretty-display `(bw ,(vector-ref classes-bw 0)))
         
         (define order 0)
         ;; Search
         (define ttt (current-milliseconds))
         (for* ([key1 keys]
                [live2 keys-bw])
               ;; (pretty-display `(search ,key1 ,pair2))
               (let* ([my-hash2 (hash-ref (vector-ref classes-bw step-bw) live2)]
                      [pass (for/and ([i ntests]) (vector-ref my-hash2 i))])
                 (when
                  pass
                  (let* ([flag2 (hash-keys (vector-ref my-hash2 0))]
                         [flag1 (entry-flag key1)]
                         [live1 (entry-live key1)]
                         [my-hash1 (hash-ref classes key1)]
                         [iterator
                          (send enum generate-inst 
                                live1 live2 flag1 flag2
                                #:try-cmp try-cmp)])
                    (pretty-display `(refine ,order ,live1 ,flag1 ,live2 ,(- (current-seconds) start-time)))
                    ;;(pretty-display `(hash ,(vector-ref my-hash2 0) ,(vector-ref my-hash2 1)))
                    ;; (when (and (equal? live1 '(0 1)) (equal? live2 '()))
                    ;;       (pretty-display "===================")
                    (refine-all my-hash1 live1 flag1 my-hash2 live2 #f iterator)
                    ;; )
                    (pretty-display `(middle-count ,middle))
                    (set! order (add1 order))
                    )))))
        
        (when (and (< size size-to) (or (not cost) (> cost (add1 size))))
              (cond
               [(and (< step-bw step-bw-max) (> step-fw (* 2 step-bw)))
                (set! step-bw (add1 step-bw))
                (newline)
                (pretty-display (format "GROW-BW: ~a" step-bw))
                ;; Grow backward
                (for ([test ntests]) (build-hash-bw-all test))
                ]

               [else
                (set! step-fw (add1 step-fw))

                ;; Grow forward
                (newline)
                (pretty-display (format "GROW-FW: ~a" step-fw))
                (set! c-behaviors 0)
                (set! c-progs 0)
                (set! classes (make-hash))
                (for ([pair (hash->list prev-classes)])
                     (when (> (- (current-seconds) start-time) time-limit)
                           (yield "timeout"))
                     (let* ([key (car pair)]
                            [live-list (entry-live key)]
                            [flag (entry-flag key)]
                            [my-hash (cdr pair)]
                            [iterator (send enum generate-inst 
                                            live-list #f flag #f
                                            #:try-cmp try-cmp)])
                       (pretty-display `(live ,live-list ,flag ,(- (current-seconds) start-time)))
                       (build-hash my-hash iterator)))
                (set! prev-classes (copy classes))
                (pretty-display `(behavior ,c-behaviors ,c-progs ,(- (current-seconds) start-time)))
                ])
              
              (main-loop (add1 size))
              )
        )
      
      (main-loop 1)
      ;; (pretty-display `(time ,(- (current-seconds) start-time)))
      (yield #f)
      )
    ))
