;;;; error-types.lisp - Type-level error definitions for eve-gate
;;;;
;;;; Defines error condition types and structures used by the eve-gate.types
;;;; package. These are foundational error types that support the type system
;;;; and validation layers. They complement (not replace) the ESI-specific
;;;; conditions defined in src/core/conditions.lisp.
;;;;
;;;; The core conditions handle HTTP/API-level errors (status codes, network
;;;; issues). These error types handle data-level issues (type mismatches,
;;;; validation failures, conversion errors).
;;;;
;;;; Hierarchy:
;;;;   eve-type-error (error)
;;;;     eve-validation-error
;;;;     eve-conversion-error
;;;;     eve-id-error

(in-package #:eve-gate.types)

;;; ---------------------------------------------------------------------------
;;; Base type system error
;;; ---------------------------------------------------------------------------

(define-condition eve-type-error (error)
  ((value :initarg :value
          :initform nil
          :reader eve-type-error-value
          :documentation "The value that caused the error")
   (expected-type :initarg :expected-type
                  :initform nil
                  :reader eve-type-error-expected-type
                  :documentation "The expected type description")
   (context :initarg :context
            :initform nil
            :reader eve-type-error-context
            :documentation "Additional context string (e.g., parameter name)"))
  (:documentation "Base condition for type system errors in eve-gate.
Signaled when data does not conform to expected EVE Online types.")
  (:report (lambda (condition stream)
             (format stream "EVE type error~@[ in ~A~]: expected ~A, got ~S"
                     (eve-type-error-context condition)
                     (eve-type-error-expected-type condition)
                     (eve-type-error-value condition)))))

;;; ---------------------------------------------------------------------------
;;; Validation error
;;; ---------------------------------------------------------------------------

(define-condition eve-validation-error (eve-type-error)
  ((errors :initarg :errors
           :initform nil
           :reader eve-validation-error-errors
           :documentation "List of validation error message strings"))
  (:documentation "Signaled when input validation fails.
Contains a list of all validation errors found.")
  (:report (lambda (condition stream)
             (format stream "EVE validation error~@[ in ~A~]:~{~%  - ~A~}"
                     (eve-type-error-context condition)
                     (or (eve-validation-error-errors condition)
                         (list (format nil "expected ~A, got ~S"
                                       (eve-type-error-expected-type condition)
                                       (eve-type-error-value condition))))))))

;;; ---------------------------------------------------------------------------
;;; Conversion error
;;; ---------------------------------------------------------------------------

(define-condition eve-conversion-error (eve-type-error)
  ((source-type :initarg :source-type
                :initform nil
                :reader eve-conversion-error-source-type
                :documentation "The source type of the value")
   (target-type :initarg :target-type
                :initform nil
                :reader eve-conversion-error-target-type
                :documentation "The target type for conversion"))
  (:documentation "Signaled when a type conversion fails.
Indicates that a value could not be converted from its source type
to the required target type.")
  (:report (lambda (condition stream)
             (format stream "EVE conversion error~@[ in ~A~]: cannot convert ~S from ~A to ~A"
                     (eve-type-error-context condition)
                     (eve-type-error-value condition)
                     (or (eve-conversion-error-source-type condition)
                         (type-of (eve-type-error-value condition)))
                     (or (eve-conversion-error-target-type condition)
                         (eve-type-error-expected-type condition))))))

;;; ---------------------------------------------------------------------------
;;; ID-specific error
;;; ---------------------------------------------------------------------------

(define-condition eve-id-error (eve-type-error)
  ((id-type :initarg :id-type
            :initform nil
            :reader eve-id-error-id-type
            :documentation "The specific ID type (e.g., :character-id, :corporation-id)"))
  (:documentation "Signaled when an EVE entity ID is invalid.
Provides specific information about the ID type that was expected.")
  (:report (lambda (condition stream)
             (format stream "Invalid EVE ~A~@[ in ~A~]: ~S~@[ (expected ~A)~]"
                     (or (eve-id-error-id-type condition) "ID")
                     (eve-type-error-context condition)
                     (eve-type-error-value condition)
                     (eve-type-error-expected-type condition)))))

;;; ---------------------------------------------------------------------------
;;; Signaling utilities
;;; ---------------------------------------------------------------------------

(defun signal-validation-error (value expected-type &key context errors)
  "Signal an eve-validation-error with restarts.

VALUE: The invalid value
EXPECTED-TYPE: Description of what was expected
CONTEXT: Parameter name or context string
ERRORS: List of error message strings

Restarts:
  USE-VALUE: Supply a replacement value
  CONTINUE: Skip validation and use the value as-is"
  (restart-case
      (error 'eve-validation-error
             :value value
             :expected-type expected-type
             :context context
             :errors errors)
    (use-value (replacement)
      :report "Supply a replacement value."
      :interactive (lambda ()
                     (format t "Enter replacement value: ")
                     (list (eval (read))))
      replacement)
    (continue ()
      :report "Skip validation and use the value as-is."
      value)))

(defun signal-conversion-error (value source-type target-type &key context)
  "Signal an eve-conversion-error with restarts.

VALUE: The value that could not be converted
SOURCE-TYPE: The type of the original value
TARGET-TYPE: The type conversion target
CONTEXT: Parameter name or context string

Restarts:
  USE-VALUE: Supply a replacement value
  USE-DEFAULT: Use a type-appropriate default value"
  (restart-case
      (error 'eve-conversion-error
             :value value
             :source-type source-type
             :target-type target-type
             :expected-type target-type
             :context context)
    (use-value (replacement)
      :report "Supply a replacement value."
      :interactive (lambda ()
                     (format t "Enter replacement value: ")
                     (list (eval (read))))
      replacement)
    (use-default ()
      :report "Use a type-appropriate default value."
      (default-for-type target-type))))

(defun signal-id-error (value id-type &key context)
  "Signal an eve-id-error with restarts.

VALUE: The invalid ID value
ID-TYPE: The expected ID type keyword (e.g., :character-id)
CONTEXT: Parameter name or context string

Restarts:
  USE-VALUE: Supply a replacement ID"
  (restart-case
      (error 'eve-id-error
             :value value
             :id-type id-type
             :expected-type (format nil "positive integer (~A)" id-type)
             :context context)
    (use-value (replacement)
      :report "Supply a replacement ID."
      :interactive (lambda ()
                     (format t "Enter replacement ID: ")
                     (list (eval (read))))
      replacement)))

;;; ---------------------------------------------------------------------------
;;; Default values by type
;;; ---------------------------------------------------------------------------

(defun default-for-type (type-keyword)
  "Return a sensible default value for the given TYPE-KEYWORD.

TYPE-KEYWORD: A keyword indicating the type (:integer, :string, :boolean, etc.)

Returns a default value appropriate for the type."
  (case type-keyword
    ((:integer :int32 :int64) 0)
    ((:number :float :double) 0.0)
    (:string "")
    (:boolean nil)
    ((:array :list) nil)
    ((:object :hash-table) (make-hash-table :test 'equal))
    (:timestamp nil)
    (otherwise nil)))
