#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; byggsteg-github

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Vendored from byggsteg-woodpecker's test/mock-byggsteg.scm, unchanged.
;; Both bridges speak the same API, and both suites should describe it the
;; same way; when the API grows a shape, it grows in both copies.  It is here
;; rather than fetched so that this project's tests need nothing but the
;; checkouts they are already made of.

;; byggsteg-woodpecker is free software: you can redistribute it and/or modify
;; it under the terms of the Lesser GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; byggsteg-woodpecker is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; Lesser GNU General Public License for more details.

;; You should have received a copy of the Lesser GNU General Public License
;; along with byggsteg-woodpecker.  If not, see <https://www.gnu.org/licenses/>.

;; A tiny mock of the Byggsteg JSON API (version 2), used by
;; test/run-tests.bash.
;;
;; It answers the three endpoints the pipeline steps call -- POST
;; /api/v2/login, POST /api/v2/jobs and GET /api/v2/logs/<log-id> -- in the
;; shapes pub/openapi.yaml describes, and reads the scenario it should play from
;; <state-dir>/scenario on every request, so a test can ask for a login failure,
;; a job that fails, a job that never finishes, and so on:
;;
;;   success            one running poll (partial output), then succeeded
;;   success-quiet      one running poll (the whole output), then succeeded with
;;                      the output left out: the answer to a `have' that is
;;                      still the log's length
;;   failure            one running poll, then failed
;;   timeout            always running
;;   login-error        the login endpoint answers 500
;;   login-no-token     the login endpoint answers 200 without a token, in the
;;                      header or in the answer
;;   login-unauthorized the login endpoint answers 401: a wrong password
;;   submit-error       the submit endpoint answers 500
;;   submit-forbidden   the submit endpoint answers 403: a token without
;;                      byggsteg:job-create
;;   submit-not-json    the submit endpoint answers 201 with a non-JSON body
;;   submit-no-log-id   the submit endpoint answers 201 with no log at all
;;   status-not-json    the status endpoint answers 200 with a non-JSON body
;;   log-not-found      the status endpoint answers 404 for the log
;;   log-error          the status endpoint answers 500
;;
;; It writes down what it was asked (`requests.txt' in the state directory), how
;; many times it was polled (`poll-count.txt'), and the `have' of every status
;; request (`have-values.txt'), so the tests can check that the steps speak
;; /api/v2 and that poll-job reads the output incrementally.
;;
;; Only the test suite uses this; the images never do.  It is written in Guile
;; -- the language Maak, which runs the suite, already needs -- so the tests
;; need no runtime the project does not already use.
;;
;; Usage: guile --no-auto-compile test/mock-byggsteg.scm <port> <state-dir>

(use-modules (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

;; ====== Constants ======

(define token
  "test-token-123")

(define email
  "user@example.org")

(define password
  "s3cret")

(define run-id
  "run-abc-123")

(define log-id
  "log-abc-123")

;; The whole output of the job, in the shape a JSON answer has to escape: a
;; newline, a quote, a backslash and a tab, so the step's own unescaping is
;; tested by every test that reads the output.
(define log-output
  "hello from the byggsteg job\nit printed \"quotes\", a \\ backslash and a\ttab\n")

;; The first line of it, which the first (still running) poll answers with.
(define log-output-first-line
  "hello from the byggsteg job\n")

(define args
  (cdr (command-line)))

(define port
  (if (pair? args) (string->number (car args)) 8799))

(define state-dir
  (if (and (pair? args) (pair? (cdr args))) (cadr args) "."))

;; ====== Little helpers ======

;; The body arrives as a bytevector (or #f when there is none).
(define (body->string body)
  (cond ((not body) "")
        ((string? body) body)
        ((bytevector? body) (utf8->string body))
        ((port? body) (get-string-all body))
        (else "")))

;; A urlencoded body as an alist of field name to value.  Both what a form
;; sends and what a script sends with --data-urlencode read the same way.
(define (form-fields body)
  (if (string-null? body)
      '()
      (map (lambda (pair)
             (let ((eq (string-index pair #\=)))
               (if eq
                   (cons (uri-decode (substring pair 0 eq))
                         (uri-decode (substring pair (+ eq 1) (string-length pair))))
                   (cons (uri-decode pair) ""))))
           (filter (lambda (pair) (positive? (string-length pair)))
                   (string-split body #\&)))))

;; A string as JSON writes it: the four characters an answer cannot carry as
;; they are, spelled out.
(define (json-escape str)
  (let loop ((chars (string->list str)) (out '()))
    (if (null? chars)
        (apply string-append (reverse out))
        (let ((c (car chars)))
          (loop (cdr chars)
                (cons (cond ((char=? c #\\) "\\\\")
                            ((char=? c #\") "\\\"")
                            ((char=? c #\newline) "\\n")
                            ((char=? c #\return) "\\r")
                            ((char=? c #\tab) "\\t")
                            (else (string c)))
                      out))))))

(define (respond code content-type body)
  (values (build-response #:code code
                          #:headers (list (cons 'content-type content-type)))
          body))

(define (respond-text code body)
  (respond code '(text/plain) body))

(define (respond-json code body)
  (respond code '(application/json) body))

;; The shape every refusal of the API is answered with.
(define (respond-error code message)
  (respond-json code (format #f "{\"error\": \"~a\"}" (json-escape message))))

;; ====== Scenario state ======

(define last-scenario #f)
(define polls (make-hash-table))

(define (append-to-state name text)
  (let ((port (open-file (format #f "~a/~a" state-dir name) "a")))
    (display text port)
    (close-port port)))

(define (scenario)
  (catch #t
         (lambda ()
           (string-trim (call-with-input-file (format #f "~a/scenario" state-dir)
                          get-string-all)))
         (lambda args "success")))

;; How many times the current scenario has polled the job, counted from one and
;; kept per log id, so a health probe against another id does not use up the
;; job's first poll.  A change of scenario resets the counts, so each group of
;; tests starts fresh.  The count the job reached is written out, so a test can
;; check that the step really polled through an in-progress answer.
(define (next-poll-number scenario id)
  (unless (equal? scenario last-scenario)
    (set! last-scenario scenario)
    (hash-clear! polls))
  (let ((number (+ 1 (hash-ref polls id 0))))
    (hash-set! polls id number)
    (when (equal? id log-id)
      (call-with-output-file (format #f "~a/poll-count.txt" state-dir)
        (lambda (port) (display number port))))
    number))

;; ====== Response bodies ======

(define (run-body status . maybe-log-id)
  (let ((run-log-id (if (null? maybe-log-id) log-id (car maybe-log-id))))
    (format #f
            "{\"id\": \"~a\", \"title\": \"a title\", \"status\": \"~a\", \"created-at\": 1750000000, \"updated-at\": 1750000001, \"log-id\": ~a}"
            run-id status
            (if run-log-id (format #f "\"~a\"" run-log-id) "null"))))

(define (log-body length)
  (format #f
          "{\"id\": \"~a\", \"title\": \"a title\", \"run-id\": \"~a\", \"created-at\": 1750000000, \"updated-at\": 1750000001, \"length\": ~a}"
          log-id run-id length))

;; One reading of a run's log: the log, the run behind it, and the output --
;; which is left out of the answer when HAVE is already the log's length, the
;; way the real API leaves it out.
(define (log-detail-body status length in-progress view have text)
  (let ((unchanged (and have (equal? have (number->string length)))))
    (format #f
            "{\"log\": ~a, \"run\": ~a, \"artifacts\": [], \"output\": {\"length\": ~a, \"in-progress\": ~a, \"view\": \"~a\", \"changed\": ~a~a}}"
            (log-body length)
            (run-body status)
            length
            (if in-progress "true" "false")
            view
            (if unchanged "false" "true")
            (if unchanged
                ""
                (format #f ", \"text\": \"~a\"" (json-escape text))))))

(define (submit-body)
  (format #f "{\"run\": ~a, \"log\": ~a}" (run-body "queued") (log-body 0)))

(define (login-body)
  (format #f
          "{\"token\": \"~a\", \"account\": {\"id\": \"user-1\", \"username\": \"tester\", \"email\": \"~a\", \"permissions\": [\"byggsteg:job-create\"]}, \"session\": {\"permissions\": [\"byggsteg:job-create\"], \"expires-at\": 1900000000}}"
          token email))

;; ====== Endpoints ======

(define (handle-login fields)
  (let ((scenario-now (scenario)))
    (cond
      ((string=? scenario-now "login-error")
       (respond-error 500 "the deployment could not sign you in"))
      ;; A token the deployment cannot check is a 401, and asking again with
      ;; the same password would be answered the same way.
      ((string=? scenario-now "login-unauthorized")
       (respond-error 401 "the email and the password do not match an account of this deployment"))
      ;; A 200 the step cannot use: it is signed in, but told nothing.
      ((string=? scenario-now "login-no-token")
       (respond-json 200 "{\"account\": {\"username\": \"tester\"}}"))
      ((and (equal? (assoc-ref fields "email") email)
            (equal? (assoc-ref fields "password") password))
       (values (build-response
                #:code 200
                #:headers (list (cons 'content-type '(application/json))
                                (cons 'x-bewaking-byggsteg token)))
               (login-body)))
      (else
       (respond-error 401 "the email and the password do not match an account of this deployment")))))

(define (handle-submit headers fields)
  (let ((scenario-now (scenario)))
    (cond
      ((string=? scenario-now "submit-error")
       (respond-error 500 "the deployment could not queue the job"))
      ((string=? scenario-now "submit-forbidden")
       (respond-error 403 "the token does not hold byggsteg:job-create"))
      ((not (equal? (assq-ref headers 'x-bewaking-byggsteg) token))
       (respond-error 401 "the token is missing or cannot be read"))
      ;; 201 answers the step cannot use: something that is not JSON at all
      ;; (an error page, a proxy's), and JSON that carries no log to follow.
      ((string=? scenario-now "submit-not-json")
       (respond-text 201 "<html><body>upstream proxy said no</body></html>"))
      ((string=? scenario-now "submit-no-log-id")
       ;; A run that was queued with no log to follow: the run says so, in the
       ;; field that is `null' rather than absent.
       (respond-json 201 (format #f "{\"run\": ~a, \"log\": null}" (run-body "queued" #f))))
      (else
       (call-with-output-file (format #f "~a/last-job-code.txt" state-dir)
         (lambda (port) (display (or (assoc-ref fields "job-code") "") port)))
       (respond-json 201 (submit-body))))))

(define (handle-log-status scenario-now uri path)
  (let* ((id (last (string-split path #\/)))
         (query (form-fields (or (uri-query uri) "")))
         (have (assoc-ref query "have"))
         (view (or (assoc-ref query "view") "rendered"))
         (number (next-poll-number scenario-now id))
         (first-line-length (string-length log-output-first-line))
         (whole-length (string-length log-output)))
    (append-to-state "have-values.txt" (format #f "~a\n" (or have "")))
    (cond
      ((string=? scenario-now "log-not-found")
       (respond-error 404 "no log with that id"))
      ((string=? scenario-now "log-error")
       (respond-error 500 "the deployment could not read the log"))
      ;; A 200 that is not a status at all: the step must fail on it, not poll
      ;; on it until the limit.
      ((string=? scenario-now "status-not-json")
       (respond-text 200 "<html><body>not a byggsteg status</body></html>"))
      ;; The output is written once and read twice: the first poll answers
      ;; with the first line and the run still going, the second with the whole
      ;; of it -- and, when the client already has that much, with no output at
      ;; all (`success-quiet').
      ((= number 1)
       (if (string=? scenario-now "success-quiet")
           (respond-json 200 (log-detail-body "running" whole-length #t view have log-output))
           (respond-json 200 (log-detail-body "running" first-line-length #t view have log-output-first-line))))
      ((string=? scenario-now "timeout")
       (respond-json 200 (log-detail-body "running" first-line-length #t view have log-output-first-line)))
      ((string=? scenario-now "failure")
       (respond-json 200 (log-detail-body "failed" whole-length #f view have log-output)))
      (else
       (respond-json 200 (log-detail-body "succeeded" whole-length #f view have log-output))))))

;; ====== The handler ======

(define (handler request body)
  (let* ((method (request-method request))
         (uri (request-uri request))
         (path (uri-path uri))
         (headers (request-headers request))
         (scenario-now (scenario))
         (fields (form-fields (body->string body))))
    (unless (string=? path "/")
      (append-to-state "requests.txt"
                       (format #f "~a ~a~a\n" method path
                               (let ((query (uri-query uri)))
                                 (if query (format #f "?~a" query) "")))))
    (cond
      ((and (eq? method 'POST) (string=? path "/api/v2/login"))
       (handle-login fields))
      ((and (eq? method 'POST) (string=? path "/api/v2/jobs"))
       (handle-submit headers fields))
      ((and (eq? method 'GET) (string-prefix? "/api/v2/logs/" path))
       (handle-log-status scenario-now uri path))
      (else
       (respond-error 404 "not found")))))

;; ====== Run ======

;; Bound to every interface rather than to the loopback one: this stands in for
;; a deployment, and the steps that talk to it run in a container, which has a
;; network of its own and cannot see the host's loopback address.
(run-server handler 'http (list #:host "0.0.0.0" #:port port))
