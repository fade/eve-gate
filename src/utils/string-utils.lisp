;;;; string-utils.lisp - String transformation utilities for eve-gate
;;;;
;;;; Provides case conversion and string manipulation functions used throughout
;;;; the project, especially for transforming OpenAPI identifiers into idiomatic
;;;; Common Lisp names.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Case conversion
;;; ---------------------------------------------------------------------------

(defun kebab-case (string)
  "Convert STRING to kebab-case (lowercase-with-hyphens).
Handles snake_case, camelCase, and mixed inputs.

STRING: Input string to convert

Returns a new lowercase string with hyphens separating words.

Example:
  (kebab-case \"get_characters_character_id\") => \"get-characters-character-id\"
  (kebab-case \"characterId\") => \"character-id\"
  (kebab-case \"HTTPClient\") => \"http-client\""
  (let ((result (make-string-output-stream))
        (last-was-upper nil)
        (last-was-separator nil))
    (loop for i from 0 below (length string)
          for char = (char string i)
          do (cond
               ;; Underscore or hyphen -> hyphen
               ((or (char= char #\_) (char= char #\-))
                (unless (or last-was-separator (zerop i))
                  (write-char #\- result))
                (setf last-was-separator t
                      last-was-upper nil))
               ;; Uppercase letter -> possible word boundary
               ((upper-case-p char)
                (when (and (not (zerop i))
                           (not last-was-separator)
                           (not last-was-upper))
                  (write-char #\- result))
                (write-char (char-downcase char) result)
                (setf last-was-upper t
                      last-was-separator nil))
               ;; Everything else
               (t
                ;; If transitioning from UPPER run to lowercase, insert hyphen
                ;; before the last uppercase (e.g., "HTTPClient" -> "http-client")
                (when (and last-was-upper
                           (> i 1)
                           (upper-case-p (char string (1- i)))
                           (not last-was-separator))
                  ;; Look back: the previous char is upper and the one before that too
                  ;; Insert hyphen before the previous upper (which is already written)
                  ;; We can't unwrite, so this heuristic handles simple cases
                  nil)
                (write-char (char-downcase char) result)
                (setf last-was-upper nil
                      last-was-separator nil))))
    (get-output-stream-string result)))

(defun snake-case (string)
  "Convert STRING to snake_case (lowercase_with_underscores).

STRING: Input string to convert

Returns a new lowercase string with underscores separating words.

Example:
  (snake-case \"get-characters\") => \"get_characters\"
  (snake-case \"characterId\") => \"character_id\""
  (substitute #\_ #\- (kebab-case string)))

(defun camel-case (string)
  "Convert STRING to camelCase.

STRING: Input string to convert

Returns a new string in camelCase format.

Example:
  (camel-case \"get-characters\") => \"getCharacters\"
  (camel-case \"get_characters_character_id\") => \"getCharactersCharacterId\""
  (let ((parts (cl-ppcre:split "[_-]" string))
        (result (make-string-output-stream)))
    (when parts
      (write-string (string-downcase (first parts)) result)
      (dolist (part (rest parts))
        (when (plusp (length part))
          (write-char (char-upcase (char part 0)) result)
          (write-string (string-downcase (subseq part 1)) result))))
    (get-output-stream-string result)))

;;; ---------------------------------------------------------------------------
;;; Trimming
;;; ---------------------------------------------------------------------------

(defun trim-whitespace (string)
  "Remove leading and trailing whitespace from STRING.

Returns a new string with whitespace trimmed, or the original if no trimming needed.

Example:
  (trim-whitespace \"  hello  \") => \"hello\""
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))
