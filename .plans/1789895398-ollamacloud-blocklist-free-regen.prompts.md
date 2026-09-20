# Prompts — ollamacloud / blocklist / free refresh / regen (1789895398)

The user's directives that produced
[1789895398-ollamacloud-blocklist-free-regen.md](./1789895398-ollamacloud-blocklist-free-regen.md),
paraphrased compactly; wording follows the session.

1. (Session open, 2026-09-20) The last plan (1788916141) had
   unfinished work — load it back up and see where we left off.

2. For ollama/ollamacloud, split the local provider into `ollama`, and
   the remote/cloud provider into `ollamacloud`. For fixtures that are
   `ollama` but are `ollamacloud`, rename their files and references
   if any, but do not update their file content, as file content as
   per spec should only refresh upon regenerations.

3. For the blocklist, which is for blocking only paid models of the
   blocked providers, add `clinepass` and `ollamacloud`, as the paid
   plans for them have expired. Furthermore, update the free models
   for their latest free models, along with all providers for their
   latest free models, as there has been a new push recently.

4. For regenerating fixtures, do that afterwards, in which we want to
   do zcode + all free models.

5. (Plan-time answer) After the renames, also queue a full zero-token
   from-identity sweep over the whole `ollamacloud` provider so every
   renamed file's content refreshes — chosen over the strict zcode +
   free scope.

6. (Plan-time answer) The regeneration covers from-identity for
   everything, plus from-capture upgrades for the free combos that
   have an invocation of record.

7. (Implementation-time finding, ratified into the plan) The `trailer`
   action failed with `model = null` in the ratifying session; the
   repair — the zcode 3.14 rollout shape drift (the dropped
   `model.role`, the `_subagent_` file scope, the renamed coding-plan
   keys) — rides this plan per commits.md ("fix it rather than commit
   without it").
