;;; apply-diff.el --- Apply LLM-style search/replace diff blocks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Caleb L. Power

;; Author: Your Name <you@example.com>
;; Maintainer: Your Name <you@example.com>
;; URL: https://github.com/yourname/apply-diff
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: convenience, tools, files

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a
;; copy of this software and associated documentation files (the "Software"),
;; to deal in the Software without restriction, including without limitation
;; the rights to use, copy, modify, merge, publish, distribute, sublicense,
;; and/or sell copies of the Software, and to permit persons to whom the
;; Software is furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
;; IN THE SOFTWARE.

;;; Commentary:

;; `apply-diff' applies LLM-style conflict-marker diff blocks to a buffer.
;; A block looks like a git conflict: a run of chevrons, the old text, a run
;; of `=', the new text, and a run of the opposite chevron:
;;
;;     <<<<
;;     old text already in the file
;;     ====
;;     the text you want instead
;;     >>>>
;;
;; Marker length is variable (>= 4) but must be consistent across all three
;; runs; either chevron may open as long as the closer is the opposite one;
;; and any text on a marker line before/after the run is ignored.  An empty
;; old side inserts NEW at the top of the file, an empty new side deletes OLD,
;; and an empty block is a no-op.
;;
;; Call `M-x apply-diff' and choose the buffer to patch (the source of the
;; block is the current buffer; the two must differ).  With no region it acts
;; on the block at point or the next one below.  With a region it applies
;; every fully-enclosed block in order, skipping edge-clipped blocks with a
;; warning and rolling the whole run back if it hits a malformed block.
;;
;; See the README for the full story.

;;; Code:

(defconst apply-diff--chevron-re "\\(<\\{4,\\}\\|>\\{4,\\}\\)"
  "Matches a run of at least three identical chevrons.")

(defun apply-diff--chomp (s)
  "Remove a single trailing newline (and optional CR) from S."
  (cond ((string-suffix-p "\r\n" s) (substring s 0 -2))
        ((string-suffix-p "\n" s)   (substring s 0 -1))
        (t s)))

(defun apply-diff--next-opener (from limit)
  "Return a plist describing the next chevron run between FROM and LIMIT, or nil."
  (when (<= from limit)
    (save-excursion
      (goto-char from)
      (when (re-search-forward apply-diff--chevron-re limit t)
        (list :run     (match-string 1)
              :bol     (line-beginning-position)
              :eol     (line-end-position)
              :run-end (match-end 1))))))

(defun apply-diff--parse-from (opener limit)
  "Parse the block beginning exactly at OPENER, searching no further than LIMIT.
OPENER is a plist from `apply-diff--next-opener'.  This does NOT skip ahead to
other openers.  Return (:status ok :old O :new N :n N :start S :end E) or
(:status malformed :start S :reason R)."
  (save-excursion
    (let* ((run        (plist-get opener :run))
           (n          (length run))
           (open-char  (aref run 0))
           (close-char (if (eq open-char ?<) ?> ?<))
           (close-re   (if (eq close-char ?<) "<\\{4,\\}" ">\\{4,\\}"))
           (open-bol   (plist-get opener :bol))
           (open-eol   (plist-get opener :eol))
           (after-open (1+ open-eol))
           (sep-bol nil) (sep-eol nil)
           (close-bol nil) (close-eol nil))
      (goto-char open-eol)
      (while (and (not sep-bol)
                  (re-search-forward "=\\{4,\\}" limit t))
        (when (= (length (match-string 0)) n)
          (setq sep-bol (line-beginning-position)
                sep-eol (line-end-position))))
      (if (not sep-bol)
          (list :status 'malformed :start open-bol
                :reason (format "no `=' separator of length %d" n))
        (goto-char sep-eol)
        (while (and (not close-bol)
                    (re-search-forward close-re limit t))
          (when (= (length (match-string 0)) n)
            (setq close-bol (line-beginning-position)
                  close-eol (line-end-position))))
        (if (not close-bol)
            (list :status 'malformed :start open-bol
                  :reason (format "no closing chevrons of length %d" n))
          (list :status 'ok :n n :start open-bol :end close-eol
                :old (apply-diff--chomp
                      (buffer-substring-no-properties after-open sep-bol))
                :new (apply-diff--chomp
                      (buffer-substring-no-properties (1+ sep-eol) close-bol))))))))

(defun apply-diff--scan (from limit)
  "Return the first VALID block at or after FROM within LIMIT.
Malformed candidates (e.g. a bash `<<<' heredoc) are skipped.  Plist or nil."
  (let ((pos from) (result nil))
    (while (and (not result) pos)
      (let ((op (apply-diff--next-opener pos limit)))
        (if (not op)
            (setq pos nil)
          (let ((b (apply-diff--parse-from op limit)))
            (if (eq (plist-get b :status) 'ok)
                (setq result b)
              (setq pos (plist-get op :run-end)))))))
    result))

(defun apply-diff--block-containing (pos)
  "Return the valid block STRICTLY containing POS (start < POS <= end), else nil.
Used to detect a region that begins partway through a block."
  (save-excursion
    (goto-char pos)
    (let ((hit nil))
      (while (and (not hit)
                  (re-search-backward apply-diff--chevron-re nil t))
        (let* ((op (apply-diff--next-opener (line-beginning-position) (point-max)))
               (b  (and op (apply-diff--parse-from op (point-max)))))
          (when (and b
                     (eq (plist-get b :status) 'ok)
                     (< (plist-get b :start) pos)
                     (<= pos (plist-get b :end)))
            (setq hit b))))
      hit)))

(defun apply-diff--locate-around-point ()
  "Return the block containing point, else the next block at/after the line."
  (let ((pt (point)))
    (or
     (save-excursion
       (goto-char pt)
       (let ((hit nil))
         (while (and (not hit)
                     (re-search-backward apply-diff--chevron-re nil t))
           (let ((blk (apply-diff--scan (line-beginning-position) (point-max))))
             (when (and blk
                        (<= (plist-get blk :start) pt)
                        (<= pt (plist-get blk :end)))
               (setq hit blk))))
         hit))
     (apply-diff--scan (line-beginning-position) (point-max)))))

(defun apply-diff--replace-in (tbuf old new deletionp)
  "In TBUF, replace the first occurrence of OLD with NEW.
When DELETIONP, also remove a now-empty line.  Warn if OLD occurs >1 times."
  (with-current-buffer tbuf
    (save-excursion
      (goto-char (point-min))
      (if (not (search-forward old nil t))
          (error "Could not find the exact text in %s to replace.  Did the file change?"
                 (buffer-name tbuf))
        (replace-match new t t)
        (when (and deletionp (bolp) (looking-at "\n"))
          (delete-char 1))
        (let ((extra (save-excursion
                       (let ((c 0))
                         (while (search-forward old nil t) (setq c (1+ c)))
                         c))))
          (if (> extra 0)
              (message "apply-diff: %s in %s (warning: %d more occurrence(s) left unchanged)"
                       (if deletionp "deleted text" "applied change")
                       (buffer-name tbuf) extra)
            (message "apply-diff: %s in %s"
                     (if deletionp "deleted text" "applied change")
                     (buffer-name tbuf))))))))

(defun apply-diff--apply (old new tbuf)
  "Apply OLD/NEW to TBUF following the empty-side conventions."
  (let ((old-empty (string= old ""))
        (new-empty (string= new "")))
    (cond
     ((and old-empty new-empty)
      (message "apply-diff: empty block (no-op); %s unchanged" (buffer-name tbuf)))
     (old-empty
      (with-current-buffer tbuf
        (save-excursion (goto-char (point-min)) (insert new "\n")))
      (message "apply-diff: inserted text at top of %s" (buffer-name tbuf)))
     (new-empty (apply-diff--replace-in tbuf old "" t))
     (t         (apply-diff--replace-in tbuf old new nil)))))

(defun apply-diff--apply-one (tbuf)
  "Locate one block around point and apply it to TBUF.
Point lands at the block's end on success, its start on failure."
  (let* ((block (or (apply-diff--locate-around-point)
                    (error "No diff block found at point or below")))
         (start (plist-get block :start))
         (end   (plist-get block :end))
         (ok    nil))
    (unwind-protect
        (progn
          (apply-diff--apply (plist-get block :old) (plist-get block :new) tbuf)
          (setq ok t))
      (goto-char (if ok end start))
      (deactivate-mark))))

(defun apply-diff--apply-region (tbuf rb re)
  "Apply every fully-enclosed diff block in [RB, RE] of the current buffer to TBUF.
Blocks are applied in order.  Partially-enclosed blocks at either edge are
skipped with a warning.  A malformed (or unappliable) block aborts the run,
rolls back every change made during it, and leaves point at the bad block's
start."
  (let ((start-pos rb)
        (warnings '())
        (applied 0)
        (last-end nil)
        (fatal-start nil)
        (fatal-reason nil)
        (partial (apply-diff--block-containing rb)))
    ;; (1) Region begins partway through a block?
    (when partial
      (push (format "region begins inside a block at position %d (skipped)"
                    (plist-get partial :start))
            warnings)
      (setq start-pos (plist-get partial :end)))
    ;; (2) Apply contained blocks inside a single rollback group on TBUF.
    (let ((handle (prepare-change-group tbuf))
          (committed nil))
      (unwind-protect
          (progn
            (activate-change-group handle)
            (let ((pos start-pos) (stop nil))
              (while (and (not stop) (not fatal-start))
                (let ((op (apply-diff--next-opener pos re)))
                  (if (null op)
                      (setq stop t)
                    (let ((b (apply-diff--parse-from op (point-max))))
                      (cond
                       ;; opener inside the region that forms no valid block
                       ((not (eq (plist-get b :status) 'ok))
                        (setq fatal-start  (plist-get b :start)
                              fatal-reason (or (plist-get b :reason) "malformed block")))
                       ;; valid block but the region cut off its end
                       ((> (plist-get b :end) re)
                        (push (format "region ends inside a block at position %d (skipped)"
                                      (plist-get b :start))
                              warnings)
                        (setq stop t))
                       ;; fully enclosed -> apply (a failure here is also fatal)
                       (t
                        (condition-case err
                            (progn
                              (apply-diff--apply (plist-get b :old) (plist-get b :new) tbuf)
                              (setq applied  (1+ applied)
                                    last-end (plist-get b :end)
                                    pos      (plist-get b :end)))
                          (error
                           (setq fatal-start  (plist-get b :start)
                                 fatal-reason (error-message-string err)))))))))))
            (unless fatal-start (setq committed t)))
        (if committed
            (accept-change-group handle)
          (cancel-change-group handle))))
    ;; (3) Report and place point.
    (deactivate-mark)
    (cond
     (fatal-start
      (goto-char fatal-start)
      (error "apply-diff: %s at position %d; rolled back %d change(s)"
             fatal-reason fatal-start applied))
     (t
      (when last-end (goto-char last-end))
      (let ((wtext (if warnings
                       (concat " (" (mapconcat #'identity (nreverse warnings) "; ") ")")
                     "")))
        (if (zerop applied)
            (message "apply-diff: no complete block applied%s" wtext)
          (message "apply-diff: applied %d block(s)%s" applied wtext)))))))

;;;###autoload
(defun apply-diff (target-buffer)
  "Apply LLM-style conflict-marker diff block(s) to TARGET-BUFFER.

Marker rules:
  * The opener is a run of at least three identical chevrons (`<' or `>').
  * The separator is a run of `=' of the SAME length.
  * The closer is a run of the OPPOSITE chevron of the SAME length.
  * Text on the same line before/after a run is ignored (`>>>note' is fine).

OLD is the text between opener and separator, NEW between separator and
closer.  Empty OLD inserts NEW at the top of TARGET-BUFFER; empty NEW deletes
OLD; both empty is a no-op.

Invocation (the source of the block is the current buffer; it must differ
from TARGET-BUFFER):
  * No region: act on the block containing point, else the next one after the
    current line.  Point ends at the block's end on success, its start on
    failure.
  * Active region: apply every block fully enclosed by the region, in order.
    Leading and inter-block non-marker text is skipped.  A block that the
    region cuts into at the start or end is skipped with a warning while the
    complete blocks are still applied.  A malformed or unappliable block
    aborts the run, rolls back all of its changes, and leaves point at the bad
    block's start."
  (interactive "bBuffer to patch: ")
  (let ((tbuf (or (get-buffer target-buffer)
                  (error "No such buffer: %s" target-buffer))))
    (when (eq tbuf (current-buffer))
      (error "Source and target are the same buffer; put the diff block elsewhere"))
    (if (use-region-p)
        (apply-diff--apply-region tbuf (region-beginning) (region-end))
      (apply-diff--apply-one tbuf))))

(provide 'apply-diff)
;;; apply-diff.el ends here
