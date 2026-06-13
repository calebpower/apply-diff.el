# apply-diff

Apply LLM-style search/replace diff blocks to a buffer, straight from Emacs.

## Why this exists

I've been asked to test out various LLMs in some of my projects. I've
explicitly prohibited them from gaining direct write access to my files for the
sake of security, but sometimes I can review files faster than I can type them
out so, for those times when I'm feeling lazy, I'd still like the ability to
apply search-and-replace blocks quickly.

That's the whole pitch. It's deliberately small and it tries hard not to do
anything surprising.

## What a block looks like

Search-and-replace blocks are basically diffs for LLMs. Yes, I know the name of
the repo is a slight misnomer--come at me. The thing is, LLMs seem to be pretty
awful at consistently counting lines and so it's a little accurate for it to do
a, well, search and replace. Also, when I'm working in a buffer, it doesn't tend
to make sense to apply things to a specific file.

```
<<<<
old text that's already in the file
====
the text I want instead
>>>>
```

A few things it's lenient about, because models are inconsistent:

1. **The marker length is up to you, as long as it's consistent.** Three or
   more, but the chevrons and the equals all have to match. Seven `<` means
   seven `=` and seven `>`. (Handy trick: if your old/new text contains lines
   that look like markers, just use *longer* markers to stay out of their way.)
2. **Either direction can open.** `<<<<` … `>>>>` or `>>>>` … `<<<<`, whichever
   the model felt like. The two chevron runs just have to face opposite ways.
   The first chunk is always the old text, the second is the new.
3. **Junk on the marker line is ignored.** Models love to scribble a comment
   next to the markers for some reason — `>>>>before` / `<<<<after`. It gets
   dropped, and the rest of the block applies fine.

## Empty sides mean something

- Nothing between the opener and the divider → it's an **insert** (the new
  text goes at the top of the file).
- Nothing between the divider and the closer → it's a **delete** (the old text
  is removed, and the empty line it leaves behind is cleaned up).
- Nothing on either side → no-op, nothing happens.

## Using it

`M-x apply-diff`, then pick the buffer you want to patch. The diff block lives
in whatever buffer you're in; the patch lands in the one you choose. (They
can't be the same buffer — see the caveats.)

How it finds the block depends on whether you've got a region:

**No region.** It checks whether your cursor is sitting inside a block. If it
is, that's the one. If it isn't, it searches forward for the next block. On
success the cursor ends up at the *end* of the block; if the patch fails (say
the old text isn't there anymore), it lands back at the *start* so you can see
what it was looking for.

**Region active.** It runs *every* complete block inside the region, in order.
Leading junk before the first block is skipped, and so is anything between
blocks. If your selection clips the first block (you started halfway in) or
the last one (you stopped halfway through), that block is skipped and you get
a warning — but the complete ones still get applied. The cursor ends up at the
end of the last block it applied.

The one thing that stops everything: a **malformed** block in the middle of
the region — mismatched marker counts, a missing closer, that kind of thing,
something that isn't just the region boundary clipping it. When that happens
it rolls back every change it made this run, drops the cursor at the start of
the bad block, and tells you what went wrong. All-or-nothing. A block whose
old text simply can't be found in the target gets treated the same way.

## Installing

With Emacs 29 or newer you can pull it straight from here with `package-vc`:

```elisp
(package-vc-install "https://github.com/calebpower/apply-diff.el")
```

Or, if you use `use-package` (Emacs 30+):

```elisp
(use-package apply-diff
  :vc (:url "https://github.com/calebpower/apply-diff.el" :rev :newest)
  :bind ("C-c d" . apply-diff))
```

The old-fashioned way works too — clone it somewhere and:

```elisp
(add-to-list 'load-path "/path/to/apply-diff.el")
(require 'apply-diff)
```

## A keybinding

I just bind it to something quick:

```elisp
(global-set-key (kbd "C-c d") #'apply-diff)
```

## Caveats / things to know

- **Matching is exact.** The old text has to appear in the target buffer
  verbatim, whitespace and all. If it shows up more than once, the first match
  wins and you get a warning about the rest.
- **Source and target have to be different buffers.** Editing the same buffer
  you're reading the blocks out of would shift everything around mid-run, so
  it just refuses.
- **Stray markers inside a region are taken seriously.** Within a region, any
  run of three-plus chevrons that doesn't complete a valid block is treated as
  a malformed block and triggers the rollback. Keep the filler between blocks
  marker-free, or just don't select stuff you didn't mean to apply.
- **Content that looks like a divider can confuse the parser.** If your
  old/new text legitimately contains a line like `====` at the same length as
  your markers, it might get read as the divider. Bump the marker length to
  dodge it.

## License

MIT. Do what you like with it.
