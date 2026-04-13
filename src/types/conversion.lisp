;;;; conversion.lisp - Type conversion utilities for ESI data
;;;;
;;;; Provides safe type conversion functions for transforming data between
;;;; ESI API formats and Common Lisp types. Handles:
;;;;   - String to integer/number parsing with error handling
;;;;   - ISO 8601 timestamp parsing to local-time objects
;;;;   - JSON value conversions (jzon types to CL types)
;;;;   - Safe coercion functions that never signal on invalid input
;;;;   - ESI-specific format conversions (datasource strings, enums)
;;;;
;;;; Design: All conversion functions follow the two-value return convention:
;;;;   (convert-X value) => (values converted-value success-p)
;;;; On failure, returns (values default-or-nil nil) without signaling.
;;;; This makes them safe for use in bulk processing pipelines.
;;;;
;;;; For conversions that should signal on failure, use the validate-and-convert
;;;; functions which wrap validation + conversion in a single call.

(in-package #:eve-gate.types)

;;; ---------------------------------------------------------------------------
;;; String to number conversions
;;; ---------------------------------------------------------------------------

(defun parse-esi-integer (string &key (default nil))
  "Parse STRING as an integer, returning DEFAULT on failure.

Safe parser that never signals. Handles leading/trailing whitespace and
numeric strings. Does not accept floating-point notation.

STRING: The string to parse
DEFAULT: Value to return on failure (default: NIL)

Returns two values:
  1. The parsed integer, or DEFAULT on failure
  2. T if parsing succeeded, NIL otherwise

Example:
  (parse-esi-integer \"12345\") => 12345, T
  (parse-esi-integer \"abc\") => NIL, NIL
  (parse-esi-integer \"12345abc\") => NIL, NIL
  (parse-esi-integer \"\" :default 0) => 0, NIL"
  (if (or (not (stringp string)) (zerop (length string)))
      (values default nil)
      (let* ((trimmed (string-trim '(#\Space #\Tab) string))
             (result (parse-integer trimmed :junk-allowed t)))
        (if (and result
                 ;; Ensure the entire string was consumed (no trailing junk)
                 (= (length trimmed)
                    (nth-value 1 (parse-integer trimmed :junk-allowed t))))
            (values result t)
            (values default nil)))))

(defun parse-esi-number (string &key (default nil))
  "Parse STRING as a number (integer or float), returning DEFAULT on failure.

Handles integer and floating-point notation. Uses READ-FROM-STRING with
safety restrictions to prevent code execution.

STRING: The string to parse
DEFAULT: Value to return on failure (default: NIL)

Returns two values: parsed-number, success-p.

Example:
  (parse-esi-number \"3.14\") => 3.14, T
  (parse-esi-number \"42\") => 42, T
  (parse-esi-number \"not-a-number\") => NIL, NIL"
  (if (or (not (stringp string)) (zerop (length string)))
      (values default nil)
      (let ((trimmed (string-trim '(#\Space #\Tab) string)))
        ;; Try integer first (faster)
        (multiple-value-bind (int-val int-success)
            (parse-esi-integer trimmed)
          (if int-success
              (values int-val t)
              ;; Try float parsing with safety
              (handler-case
                  (let* ((*read-eval* nil)  ; Prevent #. reader macro
                         (value (read-from-string trimmed)))
                    (if (numberp value)
                        (values value t)
                        (values default nil)))
                (error ()
                  (values default nil))))))))

(defun parse-esi-boolean (value &key (default nil))
  "Parse VALUE as a boolean, handling various ESI representations.

Handles:
  - CL booleans: T, NIL
  - Keywords: :TRUE, :FALSE
  - Strings: \"true\", \"false\", \"1\", \"0\"
  - JSON values: jzon may return :TRUE, :FALSE, or Lisp T/NIL

VALUE: The value to interpret as boolean
DEFAULT: Value to return for unrecognizable input

Returns two values: boolean-value, success-p.

Example:
  (parse-esi-boolean \"true\") => T, T
  (parse-esi-boolean :false) => NIL, T
  (parse-esi-boolean \"maybe\") => NIL, NIL"
  (cond
    ((eq value t) (values t t))
    ((eq value nil) (values nil t))
    ((eq value :true) (values t t))
    ((eq value :false) (values nil t))
    ((and (stringp value)
          (member value '("true" "1" "yes") :test #'string-equal))
     (values t t))
    ((and (stringp value)
          (member value '("false" "0" "no") :test #'string-equal))
     (values nil t))
    (t (values default nil))))

;;; ---------------------------------------------------------------------------
;;; Timestamp conversions
;;; ---------------------------------------------------------------------------

(defun parse-esi-timestamp (string)
  "Parse an ESI ISO 8601 timestamp string into a local-time:timestamp.

ESI timestamps are in UTC, typically formatted as:
  \"2024-01-15T12:30:45Z\"
  \"2024-01-15T12:30:45.123Z\"
  \"2024-01-15\"

STRING: ISO 8601 timestamp string from ESI

Returns two values:
  1. A local-time:timestamp object, or NIL on failure
  2. T if parsing succeeded, NIL otherwise

Example:
  (parse-esi-timestamp \"2024-01-15T12:30:45Z\")
  => @2024-01-15T12:30:45.000000Z, T"
  (when (or (not (stringp string)) (< (length string) 10))
    (return-from parse-esi-timestamp (values nil nil)))
  (handler-case
      (let ((ts (local-time:parse-timestring string :fail-on-error nil)))
        (if ts
            (values ts t)
            (values nil nil)))
    (error ()
      (values nil nil))))

(defun format-esi-timestamp (timestamp)
  "Format a local-time:timestamp as an ESI-compatible ISO 8601 string.

TIMESTAMP: A local-time:timestamp object

Returns the formatted string in \"YYYY-MM-DDTHH:MM:SSZ\" format,
or NIL if TIMESTAMP is not a valid timestamp.

Example:
  (format-esi-timestamp (local-time:now)) => \"2024-01-15T12:30:45Z\""
  (when timestamp
    (handler-case
        (local-time:format-timestring
         nil timestamp
         :format '((:year 4) #\- (:month 2) #\- (:day 2)
                   #\T (:hour 2) #\: (:min 2) #\: (:sec 2) #\Z)
         :timezone local-time:+utc-zone+)
      (error () nil))))

(defun parse-esi-date (string)
  "Parse an ESI date string (YYYY-MM-DD) into a local-time:timestamp.

Returns the timestamp at midnight UTC for the given date.

STRING: Date string in YYYY-MM-DD format

Returns two values: timestamp, success-p."
  (when (or (not (stringp string)) (/= (length string) 10))
    (return-from parse-esi-date (values nil nil)))
  (parse-esi-timestamp (concatenate 'string string "T00:00:00Z")))

(defun format-esi-date (timestamp)
  "Format a local-time:timestamp as an ESI date string (YYYY-MM-DD).

TIMESTAMP: A local-time:timestamp object

Returns the formatted date string, or NIL if invalid."
  (when timestamp
    (handler-case
        (local-time:format-timestring
         nil timestamp
         :format '((:year 4) #\- (:month 2) #\- (:day 2))
         :timezone local-time:+utc-zone+)
      (error () nil))))

(defun timestamp-to-universal-time (timestamp)
  "Convert a local-time:timestamp to a CL universal time integer.

TIMESTAMP: A local-time:timestamp object

Returns the universal time, or NIL if invalid."
  (when timestamp
    (handler-case
        (local-time:timestamp-to-universal timestamp)
      (error () nil))))

(defun universal-time-to-timestamp (universal-time)
  "Convert a CL universal time integer to a local-time:timestamp.

UNIVERSAL-TIME: A universal time integer

Returns a local-time:timestamp, or NIL if invalid."
  (when (integerp universal-time)
    (handler-case
        (local-time:universal-to-timestamp universal-time)
      (error () nil))))

;;; ---------------------------------------------------------------------------
;;; JSON value conversions
;;; ---------------------------------------------------------------------------
;;; jzon represents JSON values as:
;;;   - numbers -> CL numbers (integers, doubles)
;;;   - strings -> CL strings
;;;   - booleans -> T and NIL (or :true/:false depending on config)
;;;   - null -> :null (or NIL)
;;;   - objects -> hash-tables
;;;   - arrays -> vectors

(defun json-null-p (value)
  "Return T if VALUE represents a JSON null.
Handles both :null keyword and NIL representations."
  (or (null value) (eq value :null)))

(defun json-value-or-nil (value)
  "Return VALUE unless it represents JSON null, in which case return NIL.
Normalizes :null to NIL for consistent processing."
  (if (json-null-p value) nil value))

(defun json-to-string (value &key (default nil))
  "Convert a JSON value to a string, or return DEFAULT.

Handles strings (passthrough), numbers (princ-to-string), and null (default).

Returns two values: string-value, success-p."
  (cond
    ((stringp value) (values value t))
    ((json-null-p value) (values default nil))
    ((numberp value) (values (princ-to-string value) t))
    ((eq value t) (values "true" t))
    ((eq value :true) (values "true" t))
    ((eq value :false) (values "false" t))
    (t (values default nil))))

(defun json-to-integer (value &key (default nil))
  "Convert a JSON value to an integer, or return DEFAULT.

Handles integers (passthrough), floats (truncate), strings (parse), null (default).

Returns two values: integer-value, success-p."
  (cond
    ((integerp value) (values value t))
    ((json-null-p value) (values default nil))
    ((floatp value) (values (truncate value) t))
    ((stringp value)
     (multiple-value-bind (parsed success)
         (parse-esi-integer value)
       (if success
           (values parsed t)
           (values default nil))))
    (t (values default nil))))

(defun json-to-number (value &key (default nil))
  "Convert a JSON value to a number, or return DEFAULT.

Handles numbers (passthrough), strings (parse), null (default).

Returns two values: number-value, success-p."
  (cond
    ((numberp value) (values value t))
    ((json-null-p value) (values default nil))
    ((stringp value)
     (multiple-value-bind (parsed success)
         (parse-esi-number value)
       (if success
           (values parsed t)
           (values default nil))))
    (t (values default nil))))

(defun json-to-boolean (value &key (default nil))
  "Convert a JSON value to a boolean, or return DEFAULT.

Returns two values: boolean-value, success-p."
  (parse-esi-boolean value :default default))

(defun json-to-timestamp (value &key (default nil))
  "Convert a JSON string value to a local-time:timestamp, or return DEFAULT.

Returns two values: timestamp, success-p."
  (if (stringp value)
      (multiple-value-bind (ts success)
          (parse-esi-timestamp value)
        (if success
            (values ts t)
            (values default nil)))
      (values default nil)))

(defun json-to-list (value &key (default nil))
  "Convert a JSON array value to a list, or return DEFAULT.

jzon returns arrays as CL vectors. This converts them to lists
for idiomatic Common Lisp processing.

Returns two values: list-value, success-p."
  (cond
    ((vectorp value) (values (coerce value 'list) t))
    ((listp value) (values value t))
    ((json-null-p value) (values default nil))
    (t (values default nil))))

;;; ---------------------------------------------------------------------------
;;; ESI-specific format conversions
;;; ---------------------------------------------------------------------------

(defun datasource-to-string (datasource)
  "Convert a datasource keyword to the ESI query parameter string.

DATASOURCE: :tranquility or :singularity

Returns the lowercase string, or \"tranquility\" as default.

Example:
  (datasource-to-string :singularity) => \"singularity\"
  (datasource-to-string nil) => \"tranquility\""
  (case datasource
    (:tranquility "tranquility")
    (:singularity "singularity")
    (otherwise "tranquility")))

(defun language-to-string (language)
  "Convert a language keyword to the ESI Accept-Language string.

LANGUAGE: :en, :de, :fr, :ja, :ko, :ru, or :zh

Returns the lowercase string, or \"en\" as default.

Example:
  (language-to-string :de) => \"de\"
  (language-to-string nil) => \"en\""
  (case language
    (:en "en") (:de "de") (:fr "fr")
    (:ja "ja") (:ko "ko") (:ru "ru") (:zh "zh")
    (otherwise "en")))

(defun keyword-to-esi-string (keyword)
  "Convert a keyword to an ESI-compatible lowercase string.

Handles kebab-case keywords by converting hyphens to underscores.

KEYWORD: A keyword symbol

Returns the lowercase string with underscores.

Example:
  (keyword-to-esi-string :order-type) => \"order_type\"
  (keyword-to-esi-string :buy) => \"buy\""
  (if (keywordp keyword)
      (substitute #\_ #\- (string-downcase (symbol-name keyword)))
      (princ-to-string keyword)))

(defun esi-string-to-keyword (string)
  "Convert an ESI string value to a keyword.

Handles underscore-separated names by converting to hyphen-separated
uppercase keywords.

STRING: An ESI string value

Returns a keyword symbol.

Example:
  (esi-string-to-keyword \"order_type\") => :ORDER-TYPE
  (esi-string-to-keyword \"buy\") => :BUY"
  (when (and (stringp string) (plusp (length string)))
    (intern (string-upcase (substitute #\- #\_ string)) :keyword)))

;;; ---------------------------------------------------------------------------
;;; Batch conversion utilities
;;; ---------------------------------------------------------------------------

(defun convert-hash-table-timestamps (table &key (keys nil))
  "Convert timestamp string values in a hash-table to local-time objects.

TABLE: A hash-table with string keys (from jzon)
KEYS: List of key strings whose values should be parsed as timestamps.
      If NIL, attempts to detect timestamp values automatically by checking
      for strings that look like ISO 8601 dates.

Returns TABLE (modified in place).

Example:
  (convert-hash-table-timestamps response :keys '(\"date_founded\" \"birthday\"))"
  (when (hash-table-p table)
    (if keys
        ;; Convert specified keys
        (dolist (key keys table)
          (let ((value (gethash key table)))
            (when (stringp value)
              (multiple-value-bind (ts success)
                  (parse-esi-timestamp value)
                (when success
                  (setf (gethash key table) ts))))))
        ;; Auto-detect: scan for string values matching timestamp pattern
        (maphash (lambda (key value)
                   (when (and (stringp value)
                              (>= (length value) 10)
                              (digit-char-p (char value 0))
                              (char= (char value 4) #\-))
                     (multiple-value-bind (ts success)
                         (parse-esi-timestamp value)
                       (when success
                         (setf (gethash key table) ts)))))
                 table))
    table))

(defun convert-response-ids (table id-fields)
  "Ensure ID fields in a response hash-table are integers.

TABLE: A hash-table from jzon response parsing
ID-FIELDS: List of key strings that should contain integer IDs

Converts string representations to integers where possible.
Returns TABLE (modified in place)."
  (when (hash-table-p table)
    (dolist (key id-fields table)
      (let ((value (gethash key table)))
        (when (and value (not (integerp value)))
          (multiple-value-bind (int success)
              (json-to-integer value)
            (when success
              (setf (gethash key table) int))))))))
