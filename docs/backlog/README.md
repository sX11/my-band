# Backlog

> Deferred work for this repo: real, but not being done now -- a defect a change did not
> introduce, drift with no user-visible symptom, a fix whose blast radius exceeded its
> value, an idea worth keeping. The maintainer's own list; it gates nothing and never
> reaches a contributor.
>
> One file per item in this directory, named `YYYY-MM-DD-NN-<slug>.todo` -- `NN` a
> 2-digit sequence per date, assigned at add time, so filenames sort back into add order
> even when several items share a date. The triage call is `#worth(yes|later|no)` on the
> task line -- yes it should be fixed, later the value decision is unresolved, no it was
> decided against. `#added` is never updated, so it reads as age.
>
> Closing an item checks the box and stamps `#done(YYYY-MM-DD)`, in the commit that lands
> the fix -- the file itself never moves or is renamed. Closures are the record that
> stops a later review re-filing finished work; they are pruned on age, not kept forever.
> Managed by the zzbacklog skill; prefer its scripts to hand edits.
