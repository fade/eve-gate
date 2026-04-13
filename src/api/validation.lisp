;;;; validation.lisp - Parameter validation and type checking for generated API functions
;;;;
;;;; Provides runtime validation functions for ESI API parameters. Generated
;;;; API functions use these validators to check parameter types, ranges,
;;;; enum membership, and structural constraints before making HTTP requests.
;;;;
;;;; The validator system is driven by schema-definition and parameter-definition
;;;; structs from the spec processor. Each parameter gets a validation function
;;;; that checks:
;;;;   - Type correctness (integer, string, boolean, array)
;;;;   - Range constraints (minimum, maximum for numbers)
;;;;   - Enum membership (allowed values for string/integer enums)
;;;;   - Array constraints (minItems, maxItems, uniqueItems)
;;;;   - Required vs optional (NIL allowed for optional params)
;;;;   - Format-specific checks (int32 range, date-time format)
;;;;
;;;; Design:
;;;;   - Pure validation functions: value + schema -> (values valid-p errors)
;;;;   - Coercion functions for safe type conversion from user input
;;;;   - Validation is opt-in at runtime via *validate-parameters-p*
;;;;   - All validators are composable and individually testable
;;;;
;;;; Integration:
;;;;   Generated functions call VALIDATE-API-PARAMETERS with a parameter
;;;;   specification list before constructing the HTTP request. Invalid
;;;;   parameters signal ESI-BAD-REQUEST with detailed error information.

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *validate-parameters-p* t
  "When T, generated API functions validate parameters before making requests.
Set to NIL to disable validation for performance in trusted contexts.
Validation catches type errors, range violations, and missing required parameters.")

(defparameter *coerce-parameters-p* t
  "When T, attempt to coerce parameter values to expected types before validation.
For example, a string \"12345\" passed where an integer is expected will be
coerced to 12345. Set to NIL for strict type checking.")

;;; ---------------------------------------------------------------------------
;;; Validation result structure
;;; ---------------------------------------------------------------------------

(defstruct (validation-result (:constructor make-validation-result))
  "Result of validating a set of API parameters.

Slots:
  VALID-P: T if all validations passed
  ERRORS: List of validation error strings
  COERCED-VALUES: Alist of (parameter-name . coerced-value) pairs"
  (valid-p t :type boolean)
  (errors nil :type list)
  (coerced-values nil :type list))

;;; ---------------------------------------------------------------------------
;;; Core validation entry point
;;; ---------------------------------------------------------------------------

(defun validate-api-parameters (param-specs values)
  "Validate a set of API parameter values against their specifications.

PARAM-SPECS: List of parameter-definition structs describing expected parameters
VALUES: Plist of (:PARAM-NAME value ...) supplied by the caller

Returns a VALIDATION-RESULT struct.

Signals ESI-BAD-REQUEST if *validate-parameters-p* is T and validation fails.

Example:
  (validate-api-parameters
    (list (make-parameter-definition
            :name \"character_id\" :cl-name :character-id
            :required-p t :location :path
            :schema (make-schema-definition :type :integer :format :int32)))
    '(:character-id 12345))"
  (let ((result (make-validation-result))
        (errors '())
        (coerced '()))
    ;; Check each expected parameter
    (dolist (param param-specs)
      (let* ((cl-name (parameter-definition-cl-name param))
             (raw-value (getf values cl-name :__missing__))
             (missing-p (eq raw-value :__missing__))
             (schema (parameter-definition-schema param))
             (required-p (parameter-definition-required-p param)))
        (cond
          ;; Required parameter missing
          ((and missing-p required-p)
           (push (format nil "Required parameter ~A (~A) is missing"
                         (parameter-definition-name param) cl-name)
                 errors))
          ;; Optional parameter missing - skip validation
          (missing-p nil)
          ;; NIL value for optional param
          ((and (null raw-value) (not required-p)) nil)
          ;; Validate the supplied value
          (t
           (let ((value (if *coerce-parameters-p*
                            (coerce-parameter-value raw-value schema)
                            raw-value)))
             (multiple-value-bind (valid-p error-msg)
                 (validate-parameter-value value param)
               (if valid-p
                   (push (cons cl-name value) coerced)
                   (push error-msg errors))))))))
    ;; Check for unknown parameters (informational, not an error)
    ;; Build result
    (setf (validation-result-valid-p result) (null errors)
          (validation-result-errors result) (nreverse errors)
          (validation-result-coerced-values result) (nreverse coerced))
    ;; Signal if validation fails and checking is enabled
    (when (and *validate-parameters-p*
               (not (validation-result-valid-p result)))
      (error 'esi-bad-request
             :message (format nil "Parameter validation failed:~%~{  - ~A~%~}"
                              (validation-result-errors result))
             :endpoint nil))
    result))

;;; ---------------------------------------------------------------------------
;;; Per-parameter validation
;;; ---------------------------------------------------------------------------

(defun validate-parameter-value (value param)
  "Validate a single parameter value against its parameter-definition.

VALUE: The (possibly coerced) value to validate
PARAM: A parameter-definition struct

Returns two values:
  1. T if valid, NIL otherwise
  2. Error message string if invalid, NIL if valid"
  (let ((schema (parameter-definition-schema param))
        (name (parameter-definition-name param))
        (enum-values (parameter-definition-enum-values param)))
    ;; Check enum constraint at parameter level (overrides schema)
    (when (and enum-values value)
      (unless (member value enum-values :test #'equal)
        (return-from validate-parameter-value
          (values nil (format nil "Parameter ~A: value ~S not in allowed values ~S"
                              name value enum-values)))))
    ;; Delegate to schema validation
    (if schema
        (validate-value-against-schema value schema name)
        (values t nil))))

(defun validate-value-against-schema (value schema param-name)
  "Validate VALUE against a SCHEMA-DEFINITION, using PARAM-NAME for error messages.

VALUE: The value to validate
SCHEMA: A schema-definition struct
PARAM-NAME: Name string for error reporting

Returns two values: valid-p, error-message."
  (let ((type (schema-definition-type schema)))
    (case type
      (:integer (validate-integer-value value schema param-name))
      (:number (validate-number-value value schema param-name))
      (:string (validate-string-value value schema param-name))
      (:boolean (validate-boolean-value value param-name))
      (:array (validate-array-value value schema param-name))
      (:object (validate-object-value value schema param-name))
      (otherwise (values t nil)))))

;;; ---------------------------------------------------------------------------
;;; Type-specific validators
;;; ---------------------------------------------------------------------------

(defun validate-integer-value (value schema param-name)
  "Validate that VALUE is an integer satisfying SCHEMA constraints.

Checks: integerp, min/max range, int32/int64 bounds, enum membership."
  (unless (integerp value)
    (return-from validate-integer-value
      (values nil (format nil "Parameter ~A: expected integer, got ~A (~S)"
                          param-name (type-of value) value))))
  ;; Check format bounds
  (let ((format (schema-definition-format schema)))
    (case format
      (:int32
       (unless (<= -2147483648 value 2147483647)
         (return-from validate-integer-value
           (values nil (format nil "Parameter ~A: value ~D out of int32 range"
                               param-name value)))))
      (:int64
       (unless (<= -9223372036854775808 value 9223372036854775807)
         (return-from validate-integer-value
           (values nil (format nil "Parameter ~A: value ~D out of int64 range"
                               param-name value)))))))
  ;; Check explicit min/max from schema
  (let ((min-val (schema-definition-min-value schema))
        (max-val (schema-definition-max-value schema)))
    (when (and min-val (< value min-val))
      (return-from validate-integer-value
        (values nil (format nil "Parameter ~A: value ~D below minimum ~D"
                            param-name value min-val))))
    (when (and max-val (> value max-val))
      (return-from validate-integer-value
        (values nil (format nil "Parameter ~A: value ~D above maximum ~D"
                            param-name value max-val)))))
  ;; Check enum
  (let ((enum (schema-definition-enum-values schema)))
    (when (and enum (not (member value enum :test #'eql)))
      (return-from validate-integer-value
        (values nil (format nil "Parameter ~A: value ~D not in allowed values ~S"
                            param-name value enum)))))
  (values t nil))

(defun validate-number-value (value schema param-name)
  "Validate that VALUE is a number satisfying SCHEMA constraints."
  (unless (numberp value)
    (return-from validate-number-value
      (values nil (format nil "Parameter ~A: expected number, got ~A (~S)"
                          param-name (type-of value) value))))
  (let ((min-val (schema-definition-min-value schema))
        (max-val (schema-definition-max-value schema)))
    (when (and min-val (< value min-val))
      (return-from validate-number-value
        (values nil (format nil "Parameter ~A: value ~A below minimum ~A"
                            param-name value min-val))))
    (when (and max-val (> value max-val))
      (return-from validate-number-value
        (values nil (format nil "Parameter ~A: value ~A above maximum ~A"
                            param-name value max-val)))))
  (values t nil))

(defun validate-string-value (value schema param-name)
  "Validate that VALUE is a string satisfying SCHEMA constraints."
  (unless (stringp value)
    (return-from validate-string-value
      (values nil (format nil "Parameter ~A: expected string, got ~A (~S)"
                          param-name (type-of value) value))))
  ;; Check enum
  (let ((enum (schema-definition-enum-values schema)))
    (when (and enum (not (member value enum :test #'string-equal)))
      (return-from validate-string-value
        (values nil (format nil "Parameter ~A: value ~S not in allowed values ~S"
                            param-name value enum)))))
  ;; Check date-time format loosely
  (when (eq (schema-definition-format schema) :date-time)
    (unless (and (>= (length value) 10)
                 (digit-char-p (char value 0)))
      (return-from validate-string-value
        (values nil (format nil "Parameter ~A: value ~S does not look like a date-time"
                            param-name value)))))
  (values t nil))

(defun validate-boolean-value (value param-name)
  "Validate that VALUE is a boolean."
  (unless (or (eq value t) (eq value nil)
              (eq value :true) (eq value :false))
    (return-from validate-boolean-value
      (values nil (format nil "Parameter ~A: expected boolean, got ~A (~S)"
                          param-name (type-of value) value))))
  (values t nil))

(defun validate-array-value (value schema param-name)
  "Validate that VALUE is a sequence satisfying SCHEMA constraints."
  (unless (or (listp value) (vectorp value))
    (return-from validate-array-value
      (values nil (format nil "Parameter ~A: expected array/list, got ~A (~S)"
                          param-name (type-of value) value))))
  (let ((len (length value))
        (min-items (schema-definition-min-items schema))
        (max-items (schema-definition-max-items schema)))
    (when (and min-items (< len min-items))
      (return-from validate-array-value
        (values nil (format nil "Parameter ~A: array has ~D items, minimum is ~D"
                            param-name len min-items))))
    (when (and max-items (> len max-items))
      (return-from validate-array-value
        (values nil (format nil "Parameter ~A: array has ~D items, maximum is ~D"
                            param-name len max-items))))
    ;; Check uniqueItems
    (when (schema-definition-unique-items-p schema)
      (let ((items (coerce value 'list)))
        (unless (= (length items) (length (remove-duplicates items :test #'equal)))
          (return-from validate-array-value
            (values nil (format nil "Parameter ~A: array items must be unique"
                                param-name))))))
    ;; Validate individual items against items-schema if present
    (when-let ((items-schema (schema-definition-items-schema schema)))
      (let ((items (coerce value 'list)))
        (loop for item in items
              for i from 0
              do (multiple-value-bind (valid-p err)
                     (validate-value-against-schema
                      item items-schema
                      (format nil "~A[~D]" param-name i))
                   (unless valid-p
                     (return-from validate-array-value
                       (values nil err))))))))
  (values t nil))

(defun validate-object-value (value schema param-name)
  "Validate that VALUE is a hash-table or plist satisfying SCHEMA constraints."
  (unless (or (hash-table-p value) (listp value))
    (return-from validate-object-value
      (values nil (format nil "Parameter ~A: expected object (hash-table or plist), got ~A"
                          param-name (type-of value)))))
  ;; Check required fields for object schemas
  (when (schema-definition-required-fields schema)
    (let ((keys (if (hash-table-p value)
                    (loop for k being the hash-keys of value collect k)
                    (loop for (k v) on value by #'cddr collect k))))
      (dolist (required (schema-definition-required-fields schema))
        (let ((required-key (json-name->lisp-name required)))
          (unless (or (member required keys :test #'equal)
                      (member required-key keys :test #'eq)
                      (member (string-upcase required) keys :test #'string-equal))
            (return-from validate-object-value
              (values nil (format nil "Parameter ~A: missing required field ~A"
                                  param-name required))))))))
  (values t nil))

;;; ---------------------------------------------------------------------------
;;; Type coercion
;;; ---------------------------------------------------------------------------

(defun coerce-parameter-value (value schema)
  "Attempt to coerce VALUE to the type expected by SCHEMA.

Non-destructive: returns VALUE unchanged if coercion is not needed or not possible.

VALUE: The raw value supplied by the user
SCHEMA: A schema-definition struct describing the expected type

Returns the coerced value (or original if coercion not applicable).

Examples:
  (coerce-parameter-value \"12345\" <integer-schema>) => 12345
  (coerce-parameter-value 12345 <string-schema>) => \"12345\"
  (coerce-parameter-value \"true\" <boolean-schema>) => T"
  (when (null schema)
    (return-from coerce-parameter-value value))
  (when (null value)
    (return-from coerce-parameter-value nil))
  (let ((target-type (schema-definition-type schema)))
    (case target-type
      (:integer (coerce-to-integer value))
      (:number (coerce-to-number value))
      (:string (coerce-to-string value))
      (:boolean (coerce-to-boolean value))
      (otherwise value))))

(defun coerce-to-integer (value)
  "Coerce VALUE to an integer if possible.

Handles: integers (passthrough), strings (parse), floats (truncate).
Returns the original VALUE if coercion fails."
  (typecase value
    (integer value)
    (string (or (parse-integer value :junk-allowed t) value))
    (float (truncate value))
    (t value)))

(defun coerce-to-number (value)
  "Coerce VALUE to a number if possible."
  (typecase value
    (number value)
    (string (let ((parsed (parse-integer value :junk-allowed t)))
              (or parsed
                  (handler-case (read-from-string value)
                    (error () value)))))
    (t value)))

(defun coerce-to-string (value)
  "Coerce VALUE to a string."
  (typecase value
    (string value)
    (symbol (string-downcase (symbol-name value)))
    (number (princ-to-string value))
    (t (princ-to-string value))))

(defun coerce-to-boolean (value)
  "Coerce VALUE to a boolean."
  (cond
    ((eq value t) t)
    ((eq value nil) nil)
    ((eq value :true) t)
    ((eq value :false) nil)
    ((and (stringp value)
          (member value '("true" "yes" "1" "t") :test #'string-equal))
     t)
    ((and (stringp value)
          (member value '("false" "no" "0" "nil") :test #'string-equal))
     nil)
    (t value)))

;;; ---------------------------------------------------------------------------
;;; Parameter formatting for HTTP request construction
;;; ---------------------------------------------------------------------------

(defun format-parameter-for-request (value param)
  "Format a parameter value for inclusion in an HTTP request.

Handles conversion to string representations suitable for:
  - Path parameters (URL path substitution)
  - Query parameters (URL query string)
  - Header parameters (HTTP headers)
  - Body parameters (JSON body)

VALUE: The validated parameter value
PARAM: A parameter-definition struct

Returns the formatted string value."
  (let ((location (parameter-definition-location param))
        (schema (parameter-definition-schema param)))
    (case location
      ((:path :query :header)
       (format-scalar-for-url value schema))
      (:body value)  ; Body params are JSON-serialized separately
      (otherwise (format-scalar-for-url value schema)))))

(defun format-scalar-for-url (value schema)
  "Format a scalar value as a string for URL inclusion.

VALUE: The value to format
SCHEMA: Schema-definition for type information

Returns a string."
  (let ((type (when schema (schema-definition-type schema))))
    (typecase value
      (string value)
      (integer (princ-to-string value))
      (float (format nil "~F" value))
      ((eql t)
       (if (eq type :boolean) "true" (princ-to-string value)))
      ((eql nil)
       (if (eq type :boolean) "false" ""))
      (symbol (string-downcase (symbol-name value)))
      (list (format nil "~{~A~^,~}" value))
      (vector (format nil "~{~A~^,~}" (coerce value 'list)))
      (t (princ-to-string value)))))

;;; ---------------------------------------------------------------------------
;;; Validation form generation (for code generation)
;;; ---------------------------------------------------------------------------

(defun generate-validation-form (param)
  "Generate a Lisp form that validates a single parameter at runtime.

PARAM: A parameter-definition struct

Returns a Lisp form suitable for inclusion in generated function bodies.
The form assumes the parameter value is bound to a variable named by
the parameter's CL-NAME with the keyword prefix removed.

Example:
  For parameter 'character_id' (cl-name :CHARACTER-ID, type :integer, required):
  => (when *validate-parameters-p*
       (check-type character-id integer)
       (unless (<= 1 character-id 2147483647)
         (error 'esi-bad-request
                :message \"character_id out of range\")))"
  (let* ((cl-name (parameter-definition-cl-name param))
         (var-name (intern (symbol-name cl-name) :eve-gate.api))
         (schema (parameter-definition-schema param))
         (required-p (parameter-definition-required-p param))
         (type (when schema (schema-definition-type schema)))
         (format-kw (when schema (schema-definition-format schema)))
         (enum-values (or (parameter-definition-enum-values param)
                          (when schema (schema-definition-enum-values schema))))
         (checks '()))
    ;; Type check
    (when type
      (let ((cl-type (case type
                       (:integer 'integer)
                       (:number 'number)
                       (:string 'string)
                       (:boolean '(or boolean (member :true :false)))
                       (:array '(or list vector))
                       (otherwise nil))))
        (when cl-type
          (if required-p
              (push `(check-type ,var-name ,cl-type) checks)
              (push `(when ,var-name (check-type ,var-name ,cl-type)) checks)))))
    ;; Range check for integers
    (when (eq type :integer)
      (let ((min-val (or (when schema (schema-definition-min-value schema))
                         (case format-kw
                           (:int32 -2147483648)
                           (otherwise nil))))
            (max-val (or (when schema (schema-definition-max-value schema))
                         (case format-kw
                           (:int32 2147483647)
                           (otherwise nil)))))
        (when (or min-val max-val)
          (let ((range-check
                  (cond
                    ((and min-val max-val)
                     `(unless (<= ,min-val ,var-name ,max-val)
                        (error 'esi-bad-request
                               :message (format nil "~A: ~D out of range [~D, ~D]"
                                                ,(parameter-definition-name param)
                                                ,var-name ,min-val ,max-val))))
                    (min-val
                     `(unless (>= ,var-name ,min-val)
                        (error 'esi-bad-request
                               :message (format nil "~A: ~D below minimum ~D"
                                                ,(parameter-definition-name param)
                                                ,var-name ,min-val))))
                    (max-val
                     `(unless (<= ,var-name ,max-val)
                        (error 'esi-bad-request
                               :message (format nil "~A: ~D above maximum ~D"
                                                ,(parameter-definition-name param)
                                                ,var-name ,max-val)))))))
            (when range-check
              (push (if required-p
                        range-check
                        `(when ,var-name ,range-check))
                    checks))))))
    ;; Enum check
    (when enum-values
      (let ((enum-check
              `(unless (member ,var-name ',enum-values :test #'equal)
                 (error 'esi-bad-request
                        :message (format nil "~A: ~S not in allowed values ~S"
                                         ,(parameter-definition-name param)
                                         ,var-name ',enum-values)))))
        (push (if required-p
                  enum-check
                  `(when ,var-name ,enum-check))
              checks)))
    ;; Wrap in validation guard
    (when checks
      `(when *validate-parameters-p*
         ,@(nreverse checks)))))

;;; ---------------------------------------------------------------------------
;;; Bulk validation utilities
;;; ---------------------------------------------------------------------------

(defun validate-required-parameters (param-specs values)
  "Quick check that all required parameters are present in VALUES.

PARAM-SPECS: List of parameter-definition structs
VALUES: Plist of supplied parameter values

Returns two values:
  1. T if all required params present, NIL otherwise
  2. List of missing required parameter names"
  (let ((missing '()))
    (dolist (param param-specs)
      (when (parameter-definition-required-p param)
        (let ((cl-name (parameter-definition-cl-name param)))
          (when (eq (getf values cl-name :__missing__) :__missing__)
            (push (parameter-definition-name param) missing)))))
    (values (null missing) (nreverse missing))))

(defun extract-path-parameter-values (path-params values)
  "Extract path parameter values from VALUES plist and format for URL substitution.

PATH-PARAMS: List of parameter-definition structs for path parameters
VALUES: Plist of all supplied parameter values

Returns an alist of (\"path_param_name\" . \"formatted_value\") pairs."
  (loop for param in path-params
        for cl-name = (parameter-definition-cl-name param)
        for value = (getf values cl-name)
        when value
          collect (cons (parameter-definition-name param)
                        (format-scalar-for-url value
                                               (parameter-definition-schema param)))))

(defun extract-query-parameter-values (query-params values)
  "Extract query parameter values from VALUES plist and format for URL query string.

QUERY-PARAMS: List of parameter-definition structs for query parameters
VALUES: Plist of all supplied parameter values

Returns an alist of (\"query_param_name\" . \"formatted_value\") pairs.
Only includes parameters with non-NIL values."
  (loop for param in query-params
        for cl-name = (parameter-definition-cl-name param)
        for value = (getf values cl-name)
        when value
          collect (cons (parameter-definition-name param)
                        (format-scalar-for-url value
                                               (parameter-definition-schema param)))))

(defun substitute-path-parameters (path-template path-values)
  "Substitute path parameter values into a URL path template.

PATH-TEMPLATE: URL path with {parameter_name} placeholders
PATH-VALUES: Alist of (\"parameter_name\" . \"value\") pairs

Returns the path string with all placeholders replaced.

Example:
  (substitute-path-parameters
    \"/characters/{character_id}/assets/\"
    '((\"character_id\" . \"12345\")))
  => \"/characters/12345/assets/\""
  (let ((result path-template))
    (dolist (pair path-values result)
      (setf result
            (cl-ppcre:regex-replace
             (format nil "\\{~A\\}" (car pair))
             result
             (cdr pair))))))
