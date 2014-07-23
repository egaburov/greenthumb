#lang racket

(require "stat.rkt" "vpe/parser.rkt" "vpe/machine.rkt" "vpe/compress.rkt" "vpe/print.rkt")
(provide optimize)

(define (optimize file machine-info live-output synthesize 
                  #:dir [dir "output"] #:cores [cores 12])

  (define path (format "~a/driver" dir))
  (system (format "mkdir ~a" dir))
  (system (format "rm ~a*" path))
  ;; Use the fewest number of registers possible.
  (define-values (code map-forward map-back n) (compress-reg-space (ast-from-file file)))
  (define compressed-live-output (pre-constraint-rename live-output map-forward))
  (pretty-display "compressed-code:")
  (print-syntax code #:LR #f)
  
  (define (create-file id)
    (define (req file)
      (format "(file \"/bard/wilma/pphothil/superopt/modular-optimizer2/~a\")" file))
    (define require-files 
      (string-join 
       (map req 
            '(ast.rkt stochastic.rkt 
                      vpe/parser.rkt vpe/machine.rkt vpe/print.rkt 
                      vpe/solver-support.rkt))))
    (with-output-to-file #:exists 'truncate (format "~a-~a.rkt" path id)
      (thunk
       (pretty-display (format "#lang racket"))
       (pretty-display (format "(require ~a)" require-files))
       (pretty-display (set-machine-config-string machine-info))
       (pretty-display (format "(define code (ast-from-string \""))
       (print-syntax code #:LR #f)
       (pretty-display "\"))")
       (pretty-display (format "(define encoded-code (encode code #f))"))
       (pretty-display (format "(stochastic-optimize encoded-code ~a #:synthesize ~a #:name \"~a-~a\")" 
                               (output-constraint-string compressed-live-output)
                               synthesize path id))
       ;;(pretty-display "(dump-memory-stats)"
       )))

  (define (run-file id)
    (define out-port (open-output-file (format "~a-~a.log" path id) #:exists 'truncate))
    (define-values (sp o i e) 
      (subprocess out-port #f out-port (find-executable-path "racket") (format "~a-~a.rkt" path id)))
    sp)

  (define (wait)
    ;;(pretty-display "wait")
    (sleep 10)
    (define check-file 
      (with-output-to-string (thunk (system (format "ls ~a*.stat | wc -l" path)))))
    (define n 
      (string->number (substring check-file 0 (- (string-length check-file) 1))))
    ;;(pretty-display `(n ,check-file ,n ,cores ,(= n cores)))
    (pretty-display (format "There are currently ~a stats." n))
    (unless (= n cores)
            (wait)))

  (define (update-stats)
    (unless (andmap (lambda (sp) (not (equal? (subprocess-status sp) 'running))) processes)
        (get-stats)
        (sleep 10)
        (update-stats)))

  (define (get-stats)
    (define stats
      (for/list ([id cores])
                (create-stat-from-file (format "~a-~a.stat" path id))))
    (with-handlers* 
     ([exn? (lambda (e) (pretty-display "Error: print stat"))])
     (let ([output-id (print-stat-all stats)])
       (pretty-display (format "output-id: ~a" output-id))
       output-id
       )
     )
    )

  (define processes
    (for/list ([id cores])
              (create-file id)
              (run-file id)))
  
  (with-handlers* 
   ([exn:break? (lambda (e)
                  (for ([sp processes])
                       (when (equal? (subprocess-status sp) 'running)
                             (subprocess-kill sp #f)))
                  (sleep 5)
                  )])
   (wait)
   (update-stats)
   )
  
  (define id (get-stats))
  (define output-code (ast-from-file (format "~a-~a.best" path id)))
  (print-syntax (decompress-reg-space output-code map-back) #:LR #f)
  )


                       