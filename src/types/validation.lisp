;;;; validation.lisp - Type-level validation functions for ESI parameters
;;;;
;;;; Provides validation functions for ESI API input parameters at the type
;;;; system level. These validators operate on the eve-gate.types layer,
;;;; complementing the API-level parameter validation in src/api/validation.lisp.
;;;;
;;;; The API-level validators work with schema-definition structs from the
;;;; OpenAPI spec. These type-level validators provide:
;;;;   - Semantic validation of EVE entity IDs with specific type predicates
;;;;   - String format validation (names, descriptions, killmail hashes)
;;;;   - Timestamp format validation for ESI date strings
;;;;   - Enum validation for known ESI parameter values
;;;;   - Composite validators that combine multiple checks
;;;;
;;;; All validators follow the convention:
;;;;   (validate-X value) => (values validated-value error-string-or-nil)
;;;; Returns the (possibly cleaned) value and NIL on success, or NIL and
;;;; an error message string on failure.
;;;;
;;;; Integration: The esi-id-type-map in esi-types.lisp maps ESI parameter
;;;; names to predicates. The API validation layer (src/api/validation.lisp)
;;;; can call these validators for enhanced semantic checking.

(in-package #:eve-gate.types)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *strict-id-validation* t
  "When T, validate IDs against EVE-specific type predicates in addition
to basic integer range checks. When NIL, only check basic integer validity.
Disable for performance in bulk operations where IDs are known to be valid.")

;;; ---------------------------------------------------------------------------
;;; ID validation — semantic validation of EVE entity identifiers
;;; ---------------------------------------------------------------------------

(defun validate-esi-id (value &key (name "id") (type-predicate nil))
  "Validate VALUE as a generic ESI entity ID.

VALUE: The value to validate
NAME: Parameter name for error messages (default: \"id\")
TYPE-PREDICATE: Optional specific predicate function (e.g., #'character-id-p)

Returns two values:
  1. The validated ID (integer), or NIL on failure
  2. NIL on success, or an error message string on failure

Example:
  (validate-esi-id 12345 :name \"character_id\") => 12345, NIL
  (validate-esi-id -1 :name \"character_id\") => NIL, \"character_id: must be a positive integer, got -1\"
  (validate-esi-id \"abc\") => NIL, \"id: expected integer, got \\\"abc\\\"\""
  ;; Fast path for the common case
  (when (and (integerp value) (plusp value))
    (if (and type-predicate (not (funcall type-predicate value)))
        (return-from validate-esi-id
          (values nil (format nil "~A: value ~D out of range for type" name value)))
        (return-from validate-esi-id
          (values value nil))))
  ;; Error paths
  (cond
    ((not (integerp value))
     (values nil (format nil "~A: expected integer, got ~S" name value)))
    ((<= value 0)
     (values nil (format nil "~A: must be a positive integer, got ~D" name value)))
    (t
     ;; Should not reach here, but defensive
     (values value nil))))

(defun validate-character-id (value)
  "Validate VALUE as an EVE Online character ID.

Returns two values: validated-id, error-string.

Example:
  (validate-character-id 95465499) => 95465499, NIL
  (validate-character-id -1) => NIL, \"character_id: must be a positive integer, got -1\""
  (validate-esi-id value :name "character_id" :type-predicate #'character-id-p))

(defun validate-corporation-id (value)
  "Validate VALUE as an EVE Online corporation ID."
  (validate-esi-id value :name "corporation_id" :type-predicate #'corporation-id-p))

(defun validate-alliance-id (value)
  "Validate VALUE as an EVE Online alliance ID."
  (validate-esi-id value :name "alliance_id" :type-predicate #'alliance-id-p))

(defun validate-type-id (value)
  "Validate VALUE as an EVE Online type ID.
Note: type IDs allow 0 (unlike most other IDs)."
  (cond
    ((not (integerp value))
     (values nil (format nil "type_id: expected integer, got ~S" value)))
    ((< value 0)
     (values nil (format nil "type_id: must be non-negative, got ~D" value)))
    ((> value +max-int32+)
     (values nil (format nil "type_id: value ~D exceeds int32 range" value)))
    (t (values value nil))))

(defun validate-region-id (value)
  "Validate VALUE as an EVE Online region ID."
  (validate-esi-id value :name "region_id" :type-predicate #'region-id-p))

(defun validate-solar-system-id (value)
  "Validate VALUE as an EVE Online solar system ID."
  (validate-esi-id value :name "solar_system_id" :type-predicate #'solar-system-id-p))

(defun validate-station-id (value)
  "Validate VALUE as an EVE Online station ID."
  (validate-esi-id value :name "station_id" :type-predicate #'station-id-p))

(defun validate-structure-id (value)
  "Validate VALUE as an EVE Online player structure ID (64-bit)."
  (validate-esi-id value :name "structure_id" :type-predicate #'structure-id-p))

(defun validate-fleet-id (value)
  "Validate VALUE as an EVE Online fleet ID (64-bit)."
  (validate-esi-id value :name "fleet_id" :type-predicate #'fleet-id-p))

(defun validate-war-id (value)
  "Validate VALUE as an EVE Online war ID."
  (validate-esi-id value :name "war_id" :type-predicate #'war-id-p))

(defun validate-contract-id (value)
  "Validate VALUE as an EVE Online contract ID."
  (validate-esi-id value :name "contract_id" :type-predicate #'contract-id-p))

(defun validate-killmail-id (value)
  "Validate VALUE as an EVE Online killmail ID."
  (validate-esi-id value :name "killmail_id" :type-predicate #'killmail-id-p))

(defun validate-order-id (value)
  "Validate VALUE as an EVE Online market order ID (64-bit)."
  (validate-esi-id value :name "order_id" :type-predicate #'order-id-p))

;;; ---------------------------------------------------------------------------
;;; Automatic ID validation dispatch
;;; ---------------------------------------------------------------------------

(defun validate-id-by-parameter-name (parameter-name value)
  "Validate VALUE using the type predicate registered for PARAMETER-NAME.

Looks up the predicate in *esi-id-type-map* and validates accordingly.
Falls back to generic ESI ID validation if no specific predicate is found.

PARAMETER-NAME: String, the ESI parameter name (e.g., \"character_id\")
VALUE: The value to validate

Returns two values: validated-value, error-string.

Example:
  (validate-id-by-parameter-name \"character_id\" 95465499) => 95465499, NIL
  (validate-id-by-parameter-name \"unknown_id\" 42) => 42, NIL"
  (let ((predicate (esi-id-predicate-for parameter-name)))
    (if predicate
        (validate-esi-id value :name parameter-name :type-predicate predicate)
        (validate-esi-id value :name parameter-name))))

;;; ---------------------------------------------------------------------------
;;; String validation
;;; ---------------------------------------------------------------------------

(defun validate-esi-string (value &key (name "value")
                                       (min-length 0)
                                       (max-length nil)
                                       (allow-empty nil))
  "Validate VALUE as a string for ESI API parameters.

VALUE: The value to validate
NAME: Parameter name for error messages
MIN-LENGTH: Minimum string length (default: 0)
MAX-LENGTH: Maximum string length (default: NIL = no limit)
ALLOW-EMPTY: Whether empty strings are valid (default: NIL)

Returns two values: validated-string, error-string.

Example:
  (validate-esi-string \"hello\" :name \"search\") => \"hello\", NIL
  (validate-esi-string \"\" :name \"search\") => NIL, \"search: string must not be empty\""
  (cond
    ((not (stringp value))
     (values nil (format nil "~A: expected string, got ~S" name value)))
    ((and (not allow-empty) (zerop (length value)))
     (values nil (format nil "~A: string must not be empty" name)))
    ((< (length value) min-length)
     (values nil (format nil "~A: string length ~D below minimum ~D"
                         name (length value) min-length)))
    ((and max-length (> (length value) max-length))
     (values nil (format nil "~A: string length ~D exceeds maximum ~D"
                         name (length value) max-length)))
    (t (values value nil))))

(defun validate-eve-name (value &key (name "name"))
  "Validate VALUE as an EVE Online entity name (character, corporation, etc.).
EVE names are 3-37 characters, printable, no leading/trailing whitespace.

VALUE: The name string to validate
NAME: Parameter name for error messages

Returns two values: validated-name, error-string."
  (multiple-value-bind (val err)
      (validate-esi-string value :name name :min-length 3 :max-length 37)
    (if err
        (values nil err)
        ;; Additional EVE name checks
        (cond
          ((not (char= (char val 0) (char (string-left-trim " " val) 0)))
           (values nil (format nil "~A: name must not have leading whitespace" name)))
          ((not (char= (char val (1- (length val)))
                        (char (string-right-trim " " val) (1- (length (string-right-trim " " val))))))
           (values nil (format nil "~A: name must not have trailing whitespace" name)))
          (t (values val nil))))))

(defun validate-killmail-hash (value)
  "Validate VALUE as an EVE Online killmail hash string.
Must be a 40-character hexadecimal string.

Returns two values: validated-hash, error-string."
  (cond
    ((not (stringp value))
     (values nil (format nil "killmail_hash: expected string, got ~S" value)))
    ((/= (length value) 40)
     (values nil (format nil "killmail_hash: expected 40 characters, got ~D"
                         (length value))))
    ((not (every (lambda (c)
                   (or (digit-char-p c) (find c "abcdefABCDEF")))
                 value))
     (values nil "killmail_hash: must be hexadecimal characters only"))
    (t (values (string-downcase value) nil))))

(defun validate-search-string (value &key (name "search") (min-length 3))
  "Validate VALUE as an ESI search query string.
Search strings have a minimum length (usually 3) to prevent overly broad queries.

VALUE: The search string
NAME: Parameter name for error messages
MIN-LENGTH: Minimum search length (default: 3)

Returns two values: validated-string, error-string."
  (validate-esi-string value :name name :min-length min-length :max-length 1000))

;;; ---------------------------------------------------------------------------
;;; Timestamp and date validation
;;; ---------------------------------------------------------------------------

(defparameter *iso8601-basic-pattern*
  "^\\d{4}-\\d{2}-\\d{2}(T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})?)?$"
  "Regex pattern for basic ISO 8601 date/datetime format validation.
Matches formats like:
  2024-01-15
  2024-01-15T12:30:45Z
  2024-01-15T12:30:45.123Z
  2024-01-15T12:30:45+00:00")

(defun validate-esi-timestamp (value &key (name "timestamp"))
  "Validate VALUE as an ESI timestamp string (ISO 8601 format).
ESI uses ISO 8601 timestamps like \"2024-01-15T12:30:45Z\".

VALUE: The timestamp string to validate
NAME: Parameter name for error messages

Returns two values: validated-string, error-string.

Example:
  (validate-esi-timestamp \"2024-01-15T12:30:45Z\") => \"2024-01-15T12:30:45Z\", NIL
  (validate-esi-timestamp \"not-a-date\") => NIL, \"timestamp: invalid ISO 8601 format\""
  (cond
    ((not (stringp value))
     (values nil (format nil "~A: expected timestamp string, got ~S" name value)))
    ((< (length value) 10)
     (values nil (format nil "~A: timestamp too short (minimum YYYY-MM-DD)" name)))
    ((not (cl-ppcre:scan *iso8601-basic-pattern* value))
     (values nil (format nil "~A: invalid ISO 8601 format: ~S" name value)))
    (t
     ;; Basic range check on date components
     (let ((year (parse-integer (subseq value 0 4) :junk-allowed t))
           (month (parse-integer (subseq value 5 7) :junk-allowed t))
           (day (parse-integer (subseq value 8 10) :junk-allowed t)))
       (cond
         ((or (null year) (null month) (null day))
          (values nil (format nil "~A: could not parse date components from ~S" name value)))
         ((or (< year 2003) (> year 2100))
          ;; EVE Online launched in 2003; far future dates unlikely
          (values nil (format nil "~A: year ~D out of reasonable range [2003, 2100]" name year)))
         ((or (< month 1) (> month 12))
          (values nil (format nil "~A: month ~D out of range [1, 12]" name month)))
         ((or (< day 1) (> day 31))
          (values nil (format nil "~A: day ~D out of range [1, 31]" name day)))
         (t (values value nil)))))))

(defun validate-esi-date (value &key (name "date"))
  "Validate VALUE as an ESI date string (YYYY-MM-DD format).

VALUE: The date string
NAME: Parameter name for error messages

Returns two values: validated-string, error-string."
  (cond
    ((not (stringp value))
     (values nil (format nil "~A: expected date string, got ~S" name value)))
    ((/= (length value) 10)
     (values nil (format nil "~A: date must be YYYY-MM-DD format (10 chars), got ~D chars"
                         name (length value))))
    (t (validate-esi-timestamp value :name name))))

;;; ---------------------------------------------------------------------------
;;; Enum validation
;;; ---------------------------------------------------------------------------

(defun validate-enum (value allowed-values &key (name "value") (test #'equal))
  "Validate VALUE is a member of ALLOWED-VALUES.

VALUE: The value to check
ALLOWED-VALUES: List of allowed values
NAME: Parameter name for error messages
TEST: Comparison function (default: #'equal)

Returns two values: validated-value, error-string.

Example:
  (validate-enum \"buy\" '(\"buy\" \"sell\" \"all\") :name \"order_type\")
  => \"buy\", NIL"
  (if (member value allowed-values :test test)
      (values value nil)
      (values nil (format nil "~A: ~S not in allowed values ~S" name value allowed-values))))

(defun validate-datasource (value)
  "Validate VALUE as an ESI datasource.
Accepts keywords (:tranquility, :singularity) or strings.

Returns two values: validated-keyword, error-string."
  (cond
    ((and (keywordp value) (typep value 'esi-datasource))
     (values value nil))
    ((and (stringp value)
          (member value '("tranquility" "singularity") :test #'string-equal))
     (values (intern (string-upcase value) :keyword) nil))
    (t
     (values nil (format nil "datasource: ~S not valid, expected :tranquility or :singularity"
                         value)))))

(defun validate-language (value)
  "Validate VALUE as an ESI language code.
Accepts keywords (:en, :de, :fr, :ja, :ko, :ru, :zh) or strings.

Returns two values: validated-keyword, error-string."
  (cond
    ((and (keywordp value) (typep value 'esi-language))
     (values value nil))
    ((and (stringp value)
          (member value '("en" "de" "fr" "ja" "ko" "ru" "zh") :test #'string-equal))
     (values (intern (string-upcase value) :keyword) nil))
    (t
     (values nil (format nil "language: ~S not valid, expected one of :en :de :fr :ja :ko :ru :zh"
                         value)))))

(defun validate-order-type (value)
  "Validate VALUE as a market order type (:buy, :sell, :all)."
  (cond
    ((and (keywordp value) (typep value 'order-type))
     (values value nil))
    ((and (stringp value)
          (member value '("buy" "sell" "all") :test #'string-equal))
     (values (intern (string-upcase value) :keyword) nil))
    (t
     (values nil (format nil "order_type: ~S not valid, expected :buy, :sell, or :all" value)))))

(defun validate-route-flag (value)
  "Validate VALUE as a route calculation flag (:shortest, :secure, :insecure)."
  (cond
    ((and (keywordp value) (typep value 'route-flag))
     (values value nil))
    ((and (stringp value)
          (member value '("shortest" "secure" "insecure") :test #'string-equal))
     (values (intern (string-upcase value) :keyword) nil))
    (t
     (values nil (format nil "flag: ~S not valid, expected :shortest, :secure, or :insecure"
                         value)))))

;;; ---------------------------------------------------------------------------
;;; Numeric range validation
;;; ---------------------------------------------------------------------------

(defun validate-page-number (value)
  "Validate VALUE as an ESI pagination page number (positive integer, typically 1+).

Returns two values: validated-page, error-string."
  (cond
    ((not (integerp value))
     (values nil (format nil "page: expected integer, got ~S" value)))
    ((< value 1)
     (values nil (format nil "page: must be >= 1, got ~D" value)))
    (t (values value nil))))

(defun validate-wallet-division (value)
  "Validate VALUE as a corporation wallet division number (1-7).

Returns two values: validated-division, error-string."
  (cond
    ((not (integerp value))
     (values nil (format nil "division: expected integer, got ~S" value)))
    ((or (< value 1) (> value 7))
     (values nil (format nil "division: must be 1-7, got ~D" value)))
    (t (values value nil))))

(defun validate-standing-value (value)
  "Validate VALUE as an EVE standing value (-10.0 to 10.0).

Returns two values: validated-standing, error-string."
  (cond
    ((not (numberp value))
     (values nil (format nil "standing: expected number, got ~S" value)))
    ((or (< value -10.0) (> value 10.0))
     (values nil (format nil "standing: must be [-10.0, 10.0], got ~A" value)))
    (t (values (coerce value 'single-float) nil))))

;;; ---------------------------------------------------------------------------
;;; List/array validation
;;; ---------------------------------------------------------------------------

(defun validate-id-list (values &key (name "ids") (max-items 1000) (predicate #'esi-id-p))
  "Validate a list of entity IDs.

VALUES: A list or vector of ID values
NAME: Parameter name for error messages
MAX-ITEMS: Maximum list length (default: 1000)
PREDICATE: Per-element predicate function (default: #'esi-id-p)

Returns two values: validated-list, error-string.

Example:
  (validate-id-list '(1 2 3) :name \"character_ids\") => (1 2 3), NIL
  (validate-id-list '(1 -2 3) :name \"ids\") => NIL, \"ids[1]: value -2 failed validation\""
  (cond
    ((and (not (listp values)) (not (vectorp values)))
     (values nil (format nil "~A: expected list or vector, got ~A" name (type-of values))))
    ((> (length values) max-items)
     (values nil (format nil "~A: ~D items exceeds maximum ~D" name (length values) max-items)))
    (t
     (let ((items (coerce values 'list)))
       (loop for item in items
             for i from 0
             unless (funcall predicate item)
               do (return-from validate-id-list
                    (values nil (format nil "~A[~D]: value ~S failed validation"
                                        name i item))))
       (values items nil)))))

;;; ---------------------------------------------------------------------------
;;; Composite validators — combine multiple checks
;;; ---------------------------------------------------------------------------

(defun validate-api-input (value type &key (name "value") (required t))
  "General-purpose validator dispatching by TYPE keyword.

VALUE: The value to validate
TYPE: Keyword indicating expected type:
      :character-id, :corporation-id, :alliance-id, :type-id,
      :region-id, :solar-system-id, :station-id, :structure-id,
      :fleet-id, :war-id, :contract-id, :killmail-id, :order-id,
      :string, :integer, :boolean, :timestamp, :date,
      :page, :datasource, :language, :killmail-hash
NAME: Parameter name for error messages
REQUIRED: Whether the value is required (default: T)

Returns two values: validated-value, error-string.

Example:
  (validate-api-input 95465499 :character-id) => 95465499, NIL
  (validate-api-input nil :character-id :required nil) => NIL, NIL"
  ;; Handle nil for optional parameters
  (when (and (null value) (not required))
    (return-from validate-api-input (values nil nil)))
  (when (and (null value) required)
    (return-from validate-api-input
      (values nil (format nil "~A: required value is missing" name))))
  ;; Dispatch by type
  (ecase type
    (:character-id (validate-character-id value))
    (:corporation-id (validate-corporation-id value))
    (:alliance-id (validate-alliance-id value))
    (:type-id (validate-type-id value))
    (:region-id (validate-region-id value))
    (:solar-system-id (validate-solar-system-id value))
    (:station-id (validate-station-id value))
    (:structure-id (validate-structure-id value))
    (:fleet-id (validate-fleet-id value))
    (:war-id (validate-war-id value))
    (:contract-id (validate-contract-id value))
    (:killmail-id (validate-killmail-id value))
    (:order-id (validate-order-id value))
    (:string (validate-esi-string value :name name))
    (:integer
     (if (integerp value)
         (values value nil)
         (values nil (format nil "~A: expected integer, got ~S" name value))))
    (:boolean
     (if (or (eq value t) (eq value nil))
         (values value nil)
         (values nil (format nil "~A: expected boolean, got ~S" name value))))
    (:timestamp (validate-esi-timestamp value :name name))
    (:date (validate-esi-date value :name name))
    (:page (validate-page-number value))
    (:datasource (validate-datasource value))
    (:language (validate-language value))
    (:killmail-hash (validate-killmail-hash value))))
