;;;; test/types.lisp - Type system tests for eve-gate
;;;;
;;;; Tests for ESI types, validation, and conversion utilities

(uiop:define-package #:eve-gate/test/types
  (:use #:cl)
  (:import-from #:eve-gate.types
                ;; Type predicates
                #:character-id-p #:corporation-id-p #:alliance-id-p
                #:type-id-p #:region-id-p #:solar-system-id-p
                ;; Validation
                #:validate-character-id #:validate-corporation-id
                #:validate-esi-timestamp #:validate-esi-string
                ;; Conversion
                #:parse-esi-integer #:parse-esi-timestamp
                #:format-esi-timestamp)
  (:local-nicknames (#:t #:parachute)))

(in-package #:eve-gate/test/types)

;;; Type Predicate Tests

(t:define-test character-id-predicate
  "Test character-id-p predicate"
  (t:true (character-id-p 123456789))
  (t:true (character-id-p 1))
  (t:true (character-id-p 2147483647))  ; Max 32-bit
  (t:false (character-id-p 0))
  (t:false (character-id-p -1))
  (t:false (character-id-p "123"))
  (t:false (character-id-p nil)))

(t:define-test corporation-id-predicate
  "Test corporation-id-p predicate"
  (t:true (corporation-id-p 98000001))
  (t:true (corporation-id-p 1000001))
  (t:false (corporation-id-p 0))
  (t:false (corporation-id-p -100))
  (t:false (corporation-id-p 3.14)))

(t:define-test alliance-id-predicate
  "Test alliance-id-p predicate"
  (t:true (alliance-id-p 99000001))
  (t:true (alliance-id-p 1))
  (t:false (alliance-id-p 0))
  (t:false (alliance-id-p nil)))

(t:define-test type-id-predicate
  "Test type-id-p predicate for EVE item types"
  (t:true (type-id-p 587))      ; Rifter
  (t:true (type-id-p 34))       ; Tritanium
  (t:true (type-id-p 1))
  (t:true (type-id-p 0))        ; type-id allows 0
  (t:false (type-id-p -1)))

(t:define-test region-id-predicate
  "Test region-id-p predicate"
  (t:true (region-id-p 10000002))  ; The Forge
  (t:true (region-id-p 10000001))  ; Derelik
  (t:false (region-id-p 0))
  (t:false (region-id-p -10000002)))

(t:define-test solar-system-id-predicate
  "Test solar-system-id-p predicate"
  (t:true (solar-system-id-p 30000142))  ; Jita
  (t:true (solar-system-id-p 30002187))  ; Amarr
  (t:false (solar-system-id-p 0))
  (t:false (solar-system-id-p "Jita")))

;;; Validation Tests

(t:define-test validate-character-id-function
  "Test character ID validation"
  (multiple-value-bind (result error)
      (validate-character-id 123456789)
    (t:true result)
    (t:is eq nil error))
  
  (multiple-value-bind (result error)
      (validate-character-id -1)
    (t:false result)
    (t:true (stringp error))))

(t:define-test validate-esi-timestamp-function
  "Test ESI timestamp validation"
  (multiple-value-bind (result error)
      (validate-esi-timestamp "2024-01-15T10:30:00Z")
    (t:true result)
    (t:is eq nil error))
  
  (multiple-value-bind (result error)
      (validate-esi-timestamp "invalid-timestamp")
    (t:false result)
    (t:true (stringp error))))

(t:define-test validate-esi-string-function
  "Test ESI string validation"
  (multiple-value-bind (result error)
      (validate-esi-string "Valid Name" :min-length 1 :max-length 100)
    (t:true result)
    (t:is eq nil error))
  
  (multiple-value-bind (result error)
      (validate-esi-string "" :min-length 1)
    (t:false result)
    (t:true (stringp error))))

;;; Conversion Tests

(t:define-test parse-esi-integer-function
  "Test ESI integer parsing"
  (multiple-value-bind (result success)
      (parse-esi-integer "12345")
    (t:is = 12345 result)
    (t:true success))
  
  (multiple-value-bind (result success)
      (parse-esi-integer "not-a-number")
    (t:is eq nil result)
    (t:false success))
  
  (multiple-value-bind (result success)
      (parse-esi-integer "-42")
    (t:is = -42 result)
    (t:true success)))

(t:define-test parse-esi-timestamp-function
  "Test ESI timestamp parsing"
  (let ((timestamp (parse-esi-timestamp "2024-01-15T10:30:00Z")))
    (t:true timestamp)
    (t:true (typep timestamp 'local-time:timestamp)))
  
  (let ((timestamp (parse-esi-timestamp "invalid")))
    (t:is eq nil timestamp)))

(t:define-test format-esi-timestamp-function
  "Test ESI timestamp formatting"
  (let* ((ts (local-time:encode-timestamp 0 0 30 10 15 1 2024))
         (formatted (format-esi-timestamp ts)))
    (t:true (stringp formatted))
    (t:true (search "2024" formatted))
    (t:true (search "T" formatted))
    (t:true (search "Z" formatted))))

;;; Round-trip Tests

(t:define-test timestamp-round-trip
  "Test timestamp parsing and formatting round-trip"
  (let* ((original "2024-06-15T14:30:00Z")
         (parsed (parse-esi-timestamp original))
         (formatted (format-esi-timestamp parsed)))
    (t:is string= original formatted)))
