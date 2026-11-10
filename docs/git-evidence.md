# Git evidence

Standard 13 asks that the code is kept in Git and that everyone can commit, pull, raise merge requests and resolve merge conflicts. This page records what was actually done, so a reviewer can check each statement against the repository.

Repository: `Aritraghoshdastidar/Use_Case_22_Banking_Loan_Application_Processing` on GitHub. Branch with the complete, runnable solution: `feature/system-api-core-operations`.

## Branch model

| Branch | Purpose | State |
|---|---|---|
| `main` | Reviewed, merged work only | Has the merged pull requests below |
| `feature/system-api-core-operations` | The complete solution: all five apps, scripts, database, docker stack, documents | Tip is the latest commit on this page |
| `feature/intake-exp-api`, `feature/document-proc`, `feature/scoring-proc` | Started as one branch per app, as the team plan required | One commit each (initial structure); the finished apps were later brought into the main feature branch so a single clone runs everything |
| `feature/notification-proc` | Notification app skeleton by a second team member | Merged to `main` through pull request #4 |

Rules followed:
- Work is committed on a feature branch and reaches `main` through a pull request, not by pushing to `main`.
- One topic per commit, with a message that says what changed and why (see the history below).
- Files are staged by name, never with `git add .`, so a generated or secret file cannot slip in.
- Nothing secret is committed: encrypted properties use a key that is supplied at run time, the generated cloud configuration (`config-cloudhub.yaml`, `secure-cloudhub.yaml`) and the settings file with the account credentials are git-ignored or kept outside the repository, and a scan of the tracked files for credentials is part of each push.
- Before each push the project is cloned fresh into an empty folder and built and tested there. This found real problems (a missing Maven repository, a wrong Python path in the deploy script) that were fixed before the push.

## Pull requests

| # | Title | Branch | State | Merged |
|---|---|---|---|---|
| 1 | Add stage change, resubmit, outbox, dedupe and audit operations | `feature/system-api-core-operations` | Merged | 2026-11-05 |
| 2 | Add reference data, documents, decision, bureau mock and notification operations | `feature/system-api-core-operations` | Merged | 2026-11-05 |
| 3 | Feature/system api core operations | `feature/system-api-core-operations` | Merged | 2026-11-06 |
| 4 | feat(notification): add initial Mule application structure | `feature/notification-proc` | Merged | 2026-11-06 |

Pull request #4 was written by a different team member (Vishwashgowda) and merged by the owner, which is the commit, pull, merge-request, merge cycle between two people. The later commits, which bring the finished apps and the tooling into one branch, are ready to go to `main` in a further pull request (see "Merging into main" below).

## Commit history of the solution branch

| Commit | Date | Summary |
|---|---|---|
| 79e32b7 | 2026-11-05 | Local stack, database schema and system API foundation |
| 00d601e | 2026-11-05 | Stage change, resubmit, outbox, dedupe and audit operations |
| 7b392ad | 2026-11-05 | Reference data, documents, decision, bureau mock and notification operations |
| 5d221e9 | 2026-11-05 | Fix decision save when optional terms are missing |
| 61d72f0 | 2026-11-06 | Add the exchange to the broker definitions; pin the AMQP and Email connectors |
| 81262ea | 2026-11-06 | Refine the document verification design; pin the file store and mail connectors |
| 2255150 | 2026-11-06 | System API at 100% MUnit coverage; keep the test key out of the package |
| 97f7e0b | 2026-11-09 | Register the system API with API Manager through autodiscovery |
| d2398a1 | 2026-11-09 | Document running the system API locally and on CloudHub; scripts find the JDK and Maven on any machine |
| b7f14de | 2026-11-09 | Keep the API Manager instance id out of the local configuration |
| 463b5e9 | 2026-11-09 | Load the autodiscovery file from the resources folder so it is read only on CloudHub |
| 8ef7efa | 2026-11-09 | Add the intake, document, scoring and notification apps and the tooling to run and deploy everything |
| 6ed5122 | 2026-11-09 | Smoke check asks for the largest page so old test data does not hide new data |
| 9da747b | 2026-11-09 | Fix how the deploy script starts Python |
| d9bbdbc | 2026-11-09 | Add MuleSoft's public repository so a first build on a fresh machine resolves every dependency |
| 7de9bb5 | 2026-11-09 | Stop concurrent document saves from using up the database connection pool |
| 06788ff | 2026-11-09 | Add an upload gate to the document app that checks files before storing them |

`git log --oneline` shows the same list. Later commits (API Manager registration of the document upload API, documents) follow the same pattern.

## Contribution from a teammate (Member 3)

A teammate built a complete Google Drive version of the document app, in a separate folder, against the same contract. It was reviewed, and its best idea, checking every file before it is stored, was adapted to the S3 store and credited in the code comments, the README, the design document and in commit 06788ff. The Drive version itself was not adopted as the store because Google sign-in must be done by hand after every start, which does not suit unattended cloud runs. This is also an example of the team plan's rule that each member can implement in their own way: the choice and the reason are recorded in `docs/decisions.md`.

## Merge conflict: exercised and resolved

No conflict arose naturally, because for most of the project one person committed to a single branch. To show the procedure rather than only describe it, a conflict was created and resolved on a **throwaway clone** (nothing was pushed, so the real repository has no trace of it). Two branches started from the same commit and changed the same line of `config-local.yaml`:

```
branch demo/member-a   maxFiles: "15"      "limit a folder to 15 files"
branch demo/member-b   maxFiles: "25"      "allow 25 files in a folder"

$ git merge demo/member-b            (while on demo/member-a)
Auto-merging loan-document-proc/src/main/resources/config-local.yaml
CONFLICT (content): Merge conflict in loan-document-proc/src/main/resources/config-local.yaml
Automatic merge failed; fix conflicts and then commit the result.

verify:
<<<<<<< HEAD
  maxFiles: "15"
=======
  maxFiles: "25"
>>>>>>> demo/member-b
```

Resolution: the markers were removed and the agreed value `20` was kept, the file was staged and the merge committed:

```
*   166e0e4 Merge demo/member-b into demo/member-a: keep the agreed limit of 20 files
|\
| * b33f7e2 Demo B: allow 25 files in a folder
* | be8b7de Demo A: limit a folder to 15 files
|/
* 06788ff Add an upload gate to the document app that checks files before storing them
```

## Everyone can run the code (guideline 3)

Any team member can run the whole project from a fresh clone of the solution branch, without any account of the owner:

```
git clone https://github.com/Aritraghoshdastidar/Use_Case_22_Banking_Loan_Application_Processing.git
cd Use_Case_22_Banking_Loan_Application_Processing
git checkout feature/system-api-core-operations
```

then follow `README.md` (prerequisites, `docker compose up -d`, `scripts\run-chain.ps1`, smoke scripts). A clean-clone build and test of this exact sequence was done before the latest pushes: all unit tests pass at 100% coverage and the live scripts pass. To deploy to their own CloudHub account a member fills `cloud/anypoint-cloud.env.example` with their own services and runs the setup and deploy scripts (README section 4); credentials are never shared or committed.

## Merging into main

The solution branch is ready to be merged:
1. Open a pull request from `feature/system-api-core-operations` into `main` (title: "Complete loan application processing solution").
2. A teammate reviews it (the README and `docs/HLD.md` are the entry points; the test commands are in the README).
3. Merge with a merge commit so the history above is kept.
4. Teammates run `git checkout main && git pull` and follow the README.
