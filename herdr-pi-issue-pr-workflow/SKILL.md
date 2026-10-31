---
name: herdr-pi-issue-pr-workflow
description: >
  Herdrのペインで役割ごとにPiエージェントを起動し、GitHub Issueの実装からDraft PRの最終レビューまでを統括する。
  Pi専用のIssue→PRワークフロー（チーム編成、実装、レビュー、修正）を依頼されたときに使う。
  Herdr必須。各役割のエージェントは現在のHerdrワークスペース内のペインで動作する。
---

# Pi Issue PR Workflow

ワークフローの調整だけを行う。orchestratorのペインでIssueの実装・修正はしない。

## Boundaries

既存スキルを読み、その動作を重複実装せず正本に従う。

- ペイン、Piエージェント起動、非同期委譲、結果返却は[Herdr](../herdr/SKILL.md)。
- GitHubの読み書きはすべて[GH](../gh/SKILL.md)。
- PR全体のレビュー、再チェック、会話のResolve方針は[Review](../review/SKILL.md)。

これらのスキルを安全性と操作ルールの正本とする。すべてのエージェントは現在のHerdrワークスペースとworktree内で動かす。ワークフロー専用のランタイム、永続的な実行状態、固定のprovider/model一覧を追加しない。永続化禁止の対象は現在フェーズ、レビューラウンド、レビュー済みhead、未解決Blockerなど実行ごとの進行状態である。[チームプロファイル](#team-profiles)だけはIssueの要求に基づく例外で、名前付きのチーム編成のみを保存し、実行の進行状態は保存しない。

## Local review before filing an Issue

Issue起票前に次の表を適用する。手順は[`herdr-issue-review`](../herdr-issue-review/SKILL.md)に従う。

| 変更種別 | 起票前のローカルレビュー |
|---|---|
| 新機能・大きな変更 | 必須 |
| 明白なバグ修正・小さな変更 | 省略可 |
| どちらとも判断できない | 必須 |

変更の大小は差分行数ではなく、変更規模と不確実性で判断する。新機能、新たな契約、インターフェース変更、既存動作の変更は、差分が数行でも大きな変更とする。その実行内容がそれに応じた規模になるためである。省略可能なのは誤字、リンク切れ、原因が1つに特定された障害など、報告だけで修正方法と検証方法が明らかで、レビューが作業を遅らせるだけの場合。迷ったらレビューする。

このルールは、このワークフローが起票するすべてのIssueに適用する。レビュー時に報告した別Issue候補（[Initial review](#initial-review)）も含む。ローカルレビューはPRレビューの代わりではない。`review`ロールによるPRレビューは別途必須である。

## Preflight

ワークフローの副作用を発生させる前に、次を確認する。

1. 一意に特定できるGitHub Issue参照を要求する。なければユーザーに尋ねる。
2. Herdrの事前検証を通し、Herdrスキルの条件に加えて`HERDR_WORKSPACE_ID`を必須とする。
3. `pi`を必須とし、`pi --list-models`から実際に利用可能なモデル一覧を取得する。
4. GHスキルでIssue本文と会話コメントを読む。
5. 対象リポジトリの指示とGit/worktreeの状態を確認する。

orchestrator-first方式のworktreeチームでは、orchestratorへ渡すタスク文面は[キックオフ用テンプレート](references/kickoff-task-template.md)に従う。テンプレートが定めるのはタスク文の形式だけで、チーム表と承認ルールは[Kickoff gate](#kickoff-gate)を正本とする。

リポジトリが曖昧、worktreeに想定外の変更がある、必須ツールが利用できない場合は停止する。対象を推測したり、変更を破棄したり、代替ワークスペースを作成したりしない。

## Team specification

論理ロールは`impl`、`review`、`pr-fix`で、`ui-tester`は任意の追加ロール。実際に起動するエージェントはすべてPiとする。物理エージェントの完全な仕様には、次の3つを必ず含める。

- 正確なprovider ID。
- `pi --list-models`で当該provider配下に存在する正確なmodel ID。
- そのモデルがサポートするthinkingレベル（`off`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max`のいずれか）。

`pr-fix`は独立エージェントではなく`impl`に兼務させてもよい。`review`は必ず別エージェントであり、実装を編集してはならない。`ui-tester`も独立した物理エージェントで、仕様に含まれない場合は起動しない。`ui-tester`を使わない実行には、余分なペインや条件を追加しない。`ui-tester`は実装の編集、コミット、PR編集、GitHubレビュー投稿、PRコメント投稿を行わない。指摘はorchestratorのトリアージ材料となり、再現可能な機能不具合は必須修正、それ以外は同じ修正ラウンドに含めてよい。一方、Blocker判定の正本は`review`ロールである。`ui-tester`のタスク文面、再検証、完了、環境分離は[ui-testerロール参照](references/ui-tester-role.md)に定める。

明示されたprovider/modelの組は`pi --list-models`で検証する。ただし、そのthinking列のyes/noをレベル検証に使わない。完全な仕様は次のヘルパーで解決する。ヘルパーはインストール済みPiランタイムの公開APIから当該モデルと、サポート対象およびclamp後のthinkingレベルを確認する。

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

出力は`provider`、`model`、`requested`、`supported`、`effective`、`result`、`thinking_level_map`を含む1行のkey=value形式で、`result=ok`以外は非0終了する。`result=ok`（実効レベルが指定レベルと一致）の場合だけ仕様確定とする。それ以外は未解決として停止する。Piのデフォルトへの無断切り替え、clampされたレベルの受け入れ、aliasの独自管理、未提供IDの推測を行わない。指定の一部欠落、不正、曖昧、非対応、clamp済みの仕様はすべて未解決とする。

## Team profiles

ユーザーが承認したチーム編成は、ユーザーが所有する名前付きプロファイルとして保存する。保存、選択、検証、ヘルパーコマンド、出力契約はスキル外の[Pi Development Profiles](../_docs/pi-development.md)を正本とする。パッケージルートから`scripts/pi-development/team-record.sh`を使う。このワークフローではロール単位の部分投影ではなく、常にチーム全体を解決する。

通常の実行ではプロファイルを書き換えない。実行限定の上書きや`ui-tester`の除外は保存済み編成を変えない。正本を変更できるのは明示的な`use`/`write`操作、および次の初期化だけ。

この実行で合意したチームを`default`として初期化（bootstrap）するのは、次の条件が**すべて**成立したときだけ。

- `result=missing`
- `reason=no-profiles`
- `profiles_present=false`
- `source=default`（`active`が存在しない）
- 実行で`--profile`が指定されていない

初期化では合意した編成を`write --profile default`で保存し、承認待ちは追加しない。`profiles_present=true`なのに選択名だけが存在しない場合、`active`が壊れている場合、明示指定のプロファイルがない場合は初期化しない。これらは提案経路に戻り、ユーザーが明示した場合だけ保存する。`profiles/`や`active`を読み取れない場合も`profiles_present=false`の例外ではない。`result=invalid`（プロファイル集合の`profiles_present`は空）となるため初期化しない。

保存するのはチーム仕様のみ。対象PRは保存しないため、再利用を妨げるのは対象PRが未確定の場合だけ。`ui-tester`のタスクも再利用条件にはしない。今回指定がなければ[ui-testerロール参照の既定タスク](references/ui-tester-role.md#default-task)が使われるため。保存済みのprovider、model、thinking、編成の各値は、今回の実行でその値が指定されていない場合だけ再利用する（[Kickoff gate](#kickoff-gate)）。

未移行の資産は初回起動時の欠落ではなく`migration-required`を返す。その上に初期化しない。継続前にバックアップを伴う手動の[プロファイル移行](../_docs/pi-development-migration.md)を行う。

## Kickoff gate

[ui-testerの参加ルール](references/ui-tester-role.md#participation)に従って`ui-tester`の参加を決め、すべてのキックオフ返信に参照先で定められた固定の1行を表示して進む。文面の正本は参照先であり、ここでは再定義しない。この判定は自動で、承認待ちを追加しない。ユーザーは同じ返信で判定を上書きできる。

ロールの割当、エージェント仕様、対象PRのどれかが未確定なら、Issueと関連リポジトリの情報を確認し、進行前にチーム全体を提案する。ユーザーが指定した有効な値はすべて維持する。

提案前に[チームプロファイル](#team-profiles)の再利用を検討する。

1. `scripts/pi-development/team-record.sh resolve [--profile <name>]`で実効プロファイルを解決する。`ui-tester`参加判定がある場合は`--require-role ui-tester`を追加する。「`fallback で`」は今回の実行のプロファイル選択なので`--profile fallback`とし、`active`は変えない。「`fallback に切り替えて`」は別操作の`use fallback`（[Team profiles](#team-profiles)）。`reason=migration-required`なら代替チームを提案せず移行のために停止する。
2. 次の条件が**すべて**成立する場合だけ、表と承認待ちを省略する。すなわち、`result=ok`で、今回の実行でprovider/model/thinkingが一切明示されず、`pr-fix`が`impl`を兼務するかどうかや独自の`ui-tester`構成も指定されていないこと（Issueから導いた参加判定、または同じ返信でユーザーが上書きした参加判定は今回の参加ロールを決めるだけで、編成の明示指定とはみなさない）、そして対象PRが確定していること。この場合はプロファイルと参加するロールを示す次の**1行だけ**と参加判定の1行を出し、[Start the team](#start-the-team)へ進む。

   ```text
   前回承認編成を使用: profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking> [ui-tester=<provider>/<model>/<thinking>]
   ```

   編成はプロファイルに含まれるため、今回の実行で編成が明示されていれば再利用せず、提案と承認待ちへ進む。そうしないと今回の指定より保存済み編成を優先してしまう。参加判定の上書きは編成の明示指定ではないため、再利用経路を維持する。参加判定は出所に関係なく今回のチームだけに適用する。保存済み`ui-tester`を上書きするのは一方向だけ。参加する場合は`--require-role`によりロールのないプロファイルを`unresolved`にする。参加しない場合はロールを除いてプロファイルを再利用するが、保存済み編成から`ui-tester`は削除しない。
3. それ以外はこの節のルールに従ってチーム全体を提案し、承認を待つ。プロファイルがまったくない場合に限り、合意したチームを[Team profiles](#team-profiles)の条件で`default`として初期化する。それ以外の保存はユーザーの明示指示がある場合だけ。

提案には次の表を使う。

| Role | Assignee | Provider | Model | Thinking | Selection reason |
|---|---|---|---|---|---|

この節のチーム表と承認ルールを正本とし、[キックオフ用テンプレート](references/kickoff-task-template.md)はorchestratorに渡すタスク文面の形式だけを規定する。

モデル能力とthinkingはタスクに合わせ、必要な複雑さにだけ強い推論能力を割り当てる。不確実性とトレードオフを明示し、価格・クォータ・遅延・能力に関する根拠のない主張をしない。

標準では`impl`に`pr-fix`を兼務させる。別担当を提案するのは、専門知識が異なる、コンテキスト負荷が見込まれる、独立して理解できる領域に変更がまたがるなど、具体的な引き継ぎ上の利点がある場合だけ。その理由を提案に示す。

Issue本文とリポジトリ規約から、今回の実行で作る対象PRを決定して提案に明記する。

- 複数PR計画（例：インフラPR①のブランチを基にUI PR②を作る）がある場合、今回作るPRの位置を`対象 PR: <position>/<total>`（例：`対象 PR: 1/2`）と記載する。1回の実行で作るPRは必ず1件。複数PRのIssueは連続した実行で完了し、後続の実行では前回のロールペインを再利用する（[Sequential runs](references/sequential-runs.md)）。
- それ以外は`対象 PR: single`。
- 計画はあるが今回の位置を確定できない場合は、推測せず提案内で対象を未解決のままにし、追加の停止・承認ループを作らず既存の承認を待つ。

GitHubはdefaultブランチへ到達したコミットメッセージ中のクローズキーワードを解釈するため、その使用判断も同じ提案に含める。`close #<issue>`、`closes`、`fixes`、`resolves`などのクローズキーワードをPR本文とコミットメッセージに使うのは、今回が計画の最後のPRで、かつリポジトリ規約がキーワードを要求する場合だけ。それ以外は両方で`Related to #<issue>`などの非クローズ参照を使う。リポジトリ規約だけでは最後のPRとは判断できない。Issueに計画がない場合はクローズキーワードなしを既定とし、承認済み提案で別途定められた場合にだけ従う。スタックしたPRでbaseブランチとworkブランチが異なる場合、その差とマージ時のクローズキーワードの危険性を明記する。分割と綴りの例は[複数PRのIssue参照](references/multi-pr-issue.md)を参照する。

今回の実行で指定された`ui-tester`タスクはそのまま保持して委譲文に含め、チーム表へ列を追加しない。指定がなければ[ui-testerの既定タスク](references/ui-tester-role.md#default-task)を使い、タスクについて追加承認を待たない。

**チーム全体の提案についてユーザーの明示的な承認を待つ。** 承認前にはブランチの作成・切り替え、ペイン作成、エージェント起動、GitHub書き込みを行わない。割当がすべて有効かつ確定し、対象PRも確定した場合だけ、承認されたチームを要約して追加の承認ラウンドなしに進む。

合意済みチームは今回の実行で使い、保存プロファイルを変更しない。編成は実行限定であり、保存済み`ui-tester`の除外、`pr-fix`の分離、provider/model/thinkingの上書きは保存先に反映しない。唯一の自動保存は[Team profiles](#team-profiles)の条件によるbootstrapで、`team-record.sh write --profile default`で保存する。それ以外は明示指示がある場合だけ`team-record.sh write --profile <name>`を使い、`--pr-fix-shared-with-impl`や参加ロールの選択を含む合意済みの編成そのものを保存する。今回指定された値はプロファイルより優先し、上書きされた保存値を黙って使わず、未解決の値も保存しない。「編成見せて」の依頼では、`resolve`の出力からチーム表を表示するだけで、承認待ちも変更も行わない。

## Start the team

チーム確定後に次を行う。

1. リポジトリの現状と指示からbaseブランチを決定する。
2. 指示に従って専用workブランチを作る。既存のworkブランチは、ユーザーが明示的に選択した場合だけ使う。保護されたbaseへ直接pushしない。
3. 各参加ロールについて、このorchestratorが同一Issueの以前の実行から使っているペインを再利用できるか判断する。[Sequential runs](references/sequential-runs.md)の条件を**すべて**満たす場合だけ再利用する。満たさない、または確認できない場合は新しいペインが必要とする。判断には現在の会話だけを使う。
4. 新たに必要な物理エージェント1体につきシェルペインを1つ用意する。複数の場合はHerdrレイアウトプランナーで新規ペインをまとめてグリッドに配置し、セル順のIDを取得する。

   ```bash
   herdr/scripts/pane-layout.sh apply --count <new physical agents> --label <team label>
   ```

   `--count`は**新規ペイン数だけ**であり、再利用分を含めない。0の場合は何も作らずプランナーも呼ばない。新規が1つの場合、最小数2のプランナーは使えないため、Herdrスキルの単一ペイン規則でorchestratorのペインから分割する。
5. 各新規ペインで検証済みの値を使ってエージェントを起動する。

   ```bash
   herdr agent start <name> --kind pi --pane <pane-id> -- \
     --provider <provider> --model <model> --thinking <thinking>
   ```

6. 新規ペインには責務に基づいたエージェント名とペインラベルを付ける。再利用するペインの既存の名前とラベルは維持する。
7. 作業を送る前に、起動した各Piペインのランタイム状態を確認し、実効provider/model/thinkingが承認済みの仕様と完全一致することを検証する。不一致・検証不能なら停止する。

起動するのは参加ロールだけ。`impl`（独立させなければ`pr-fix`を兼務）と`review`は常に参加し、判定により`ui-tester`を追加する。`pane-layout.sh apply --count <new physical agents>`にはチーム総数ではなく新規ペイン数を渡す。再利用なしの場合、兼務チームは2つ、別`pr-fix`または`ui-tester`の片方を追加すると3つ、両方あれば4つとなる。部分再利用では新規数が減り、全ロール再利用なら0になる。プランナーは新規ペインを計画済みグリッドに収め、呼び出し元のタブに収まらない場合はラベル付きの新タブを作る（[pane layout](../herdr/references/pane-layout.md#tab-policy)）。そのため4ペインチームが新タブで起動する場合もある。起動結果が失敗・不明の場合、実装を開始せず、作成済みペインも自動で閉じない。観測した状態を報告する。

開始時にタスクを受け取るのは`impl`だけ。`review`と独立した`pr-fix`は担当フェーズまで待機する。`ui-tester`もDraft PR作成まで待機する。再利用する各ペインは、この実行で最初の委譲をする前にcompactする（[Sequential runs](references/sequential-runs.md)）。compactはタスクではなくTUIコマンドなので、キックオフで作業を受け取るロールの条件は変わらない。

## Delegation contract

Use the Herdr skill's asynchronous parent-to-child wrapper for each task. Include the role, Issue, base and work branches, current PR when available, repository instructions, phase-specific scope, and expected report. Never assume that agents share conversation context merely because they share a worktree, and never because a pane is reused: compaction does not carry the previous run's facts, so the task text does ([Sequential runs](references/sequential-runs.md)).

Each role must return `completed` or `blocked` through the direct-parent result helper. Its report must identify the work performed, verification, relevant commit or PR, and any unresolved condition. A submitted prompt is not proof of completion; inspect agent state and output before advancing. Await returns without blocking the orchestrator pane: a return is queued while the pane is executing tool calls, so do not hold the pane in long foreground commands such as `sleep`-based polling (see the Herdr skill's async delegation rules).

`completed` requires every verification mandated by the Issue and repository instructions to have run and succeeded. A failed, skipped, or unavailable required check must return `blocked` with its command and result; never advance merely because verification finished.

Track the Issue, team assignments and pane IDs, base and work branches, current phase, PR, reviewed head, review round, and unresolved Blockers only in the current conversation. Do not write this process state to disk; the [team profiles](#team-profiles) hold team compositions only.

### Implementation

Ask `impl` to:

1. read the Issue and comments;
2. implement only the Issue scope and follow repository instructions;
3. run and pass every required test, check, formatter, and linter;
4. commit and push the work branch, applying the close keyword decision from the Kickoff gate to the commit messages;
5. use the GH skill to create a Draft PR with the required repository-specific description, applying the same decision to the PR body;
6. return the commit, verification results, and PR number and URL.

Do not advance without successful required verification, a confirmed push, and a Draft PR. If required verification fails or cannot run, require `blocked` and stop before treating the implementation as complete. Do not treat an unknown Git or GitHub result as success or blindly repeat it.

### ui-tester verification

When the specification includes a `ui-tester`, re-decide participation from the Draft PR's actual diff ([Draft PR re-judgment](references/ui-tester-role.md#draft-pr-re-judgment)) and delegate only when the diff changes a user-visible surface. The `ui-tester`'s task may run in parallel with the Round 1 review. Delegate the task the Kickoff gate set — a task this run supplied, or otherwise the default E2E task; never replace a supplied task with the default.

The `ui-tester` produces the evidence defined in [the ui-tester role reference](references/ui-tester-role.md#evidence) — screenshots by default, a WebM video only for a claim that lives in time, no GIF and no text overlays, every artifact inside `PW_ARTIFACT_DIR` and within the 10 MB attachment limit, with screenshots as the recorded fallback when a video cannot meet it. It returns each artifact's absolute path with the verification item it proves, and it never posts anything to GitHub itself, comments included: the orchestrator posts the evidence and checks the sizes before posting. The same evidence contract applies to the re-verification below.

Post the evidence the return carries with the GH skill's `comments.create` and an explicit `grant`, as the PR comment whose shape is fixed in [the evidence posting shape](references/ui-tester-role.md#evidence-posting). The comment's body starts with the marker that names the head and references every attachment, and the orchestrator searches the PR comments for that marker before posting. A comment for the same head is reused only when its body already names every item this return passes; when items were added, post a new comment, since `comments.update` cannot add attachments. A fix push moves the head, so each head gets its own comment, at most one per review round.

Before posting, check every artifact exists, keeps an attachment-eligible extension, and is within 10 MB — the gh CLI's own check does not stop a Free-plan attachment at 10 MB. Treat `MISSING_DEPENDENCY`, `ATTACH_UNSUPPORTED`, and `ATTACH_INVALID` as deterministic pre-write errors (`retryable=false`): report the cause and stop before completion instead of retrying. Treat `unknown_outcome` as unknown: read the PR comments for the marker before deciding, and stop with the observed state when that read cannot settle it. Never report completion while an item the return passed has no attached evidence.

The `ui-tester` adds no review round. The `ui-tester`'s findings are triage input: reproducible functional defects are mandatory fixes, other findings may join the same fix round, and the `review` role remains the authority for Blocker determination. The `ui-tester`'s fixes are routed to the assigned `pr-fix` agent; a fix push that addresses `ui-tester` findings is a normal fix push and consumes the existing three-round review budget. After Round 3, a mandatory `ui-tester` finding stops the run and is reported without extra rounds.

After every fix push, the `ui-tester` re-verifies on the latest head, limited to the reported items and the affected scope, and reports each as pass or unverified. Paid-API verification for the `ui-tester` is off by default and the Issue's verification policy wins. The `ui-tester`'s task text, re-verification checklist, and environment separation values are in [the ui-tester role reference](references/ui-tester-role.md).

### Initial review

Give the PR URL or number to `review` and explicitly ask it to use the Review skill in PR mode. The reviewer posts its result to GitHub and returns the review round, head commit, finding counts, and whether a Blocker remains.

Pass the user's operational and compatibility requirements from the request to the reviewer in the delegation text; the Review skill records the applied assumption in every review result. Report any separate Issue candidates without counting them as findings or blocking LGTM.

The reviewer never implements a fix, approves the PR, or merges it. Nit, Consider, and FYI findings do not block this workflow when the Review skill reports LGTM.

### Review fixes

When a Blocker remains, send the PR and exact posted feedback to the assigned `pr-fix` agent. If `impl` owns `pr-fix`, reuse the same agent and pane.

Ask the fixer to:

1. read the current PR feedback through the GH skill;
2. address the reported Blockers without expanding scope;
3. rerun and pass every required verification for the updated head;
4. commit and push the fix;
5. reply to the relevant review comments when required by repository instructions;
6. return the commit, verification, replies, and unresolved feedback.

The fixer must return `blocked` when required verification fails or cannot run. It must not resolve review conversations.

### Review loop

After a confirmed fix push, ask the same `review` agent explicitly to recheck all prior unresolved findings and review the latest head using the Review skill's recheck procedure (`review/references/recheck.md`). Carry forward the user's operational and compatibility requirements. Do not request only normal PR mode or make the recheck optional: the delegation must require both reclassification of the prior root comments and the latest-head review within that reference's scope. Recheck replies alone are never sufficient to establish LGTM.

The recheck delegation also carries this workflow's auto-resolve designation: after posting its classification replies and a verified LGTM, the reviewer either resolves the threads it classified `Resolved` (see Completion) or hands the verified target set to the orchestrator, which then resolves them. The Review skill's recheck reference (`references/recheck.md`, "Workflow コンテキストの自動 Resolve") is the canonical rule for the trigger, the reply confirmation, the lightweight checks, and the execution; the workflow only designates auto-resolve and never restates or re-derives that policy. On handoff, the reviewer's recheck report must include each target as the tuple `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` (see the Review skill's recheck reporting spec), and the orchestrator treats that reported set as the target authority rather than re-deriving targets from a fresh read. The orchestrator resolves each target with `review-threads.resolve` and confirms completion by re-reading it with `review-threads.read` and verifying `resolved=true`.

Count the initial PR-wide review as Round 1 and allow at most three review rounds in total.

- If the latest verified review of the current head posts LGTM with no Blocker, complete the workflow.
- If a Blocker remains before Round 3, repeat fix then recheck.
- If a Blocker remains after Round 3, stop and report the remaining failure condition and evidence.
- If any agent returns `blocked`, stop the phase and request the needed decision or input.

Do not introduce a separate retry, queue, or state machine around Herdr or GitHub operations.

## Completion

Complete only when all of the following are confirmed:

- the Issue implementation is pushed to the PR head;
- every required verification has succeeded on the current PR head;
- the PR exists and remains Draft;
- the current PR head matches the commit covered by the latest verified Review-skill LGTM review (including a recheck's latest-head review under its canonical scope), with no Blocker;
- the PR body and the commit messages follow the close keyword decision for the target PR determined at the Kickoff gate;
- no required review fix remains unaddressed;
- when a ui-tester is specified only, every item it took on is either verified as passing on the current PR head or reported as unverified with its reason, and every item it passed on the current PR head has its evidence attached in that head's evidence comment, judged by reading that comment ([ui-tester verification](#ui-tester-verification)); the ui-tester condition adds to, and never replaces, the review LGTM requirement;
- every thread the latest recheck classified `Resolved` has been resolved after reply confirmation and the lightweight checks (this workflow's auto-resolve), while `Partial`, `Unresolved`, `Unknown`, other authors' threads, and user-decision discussions remain open;
- a `ui-tester` the run included but never delegated to is closed with `herdr pane close <pane-id>` and the one line in [Completion cleanup](references/ui-tester-role.md#completion-cleanup), while every pane that took a delegation stays open.

Conversation resolution follows the Review skill's Resolve policy, which is canonical in its recheck reference (`references/recheck.md`). Outside this workflow it remains explicit instruction only. Within the fix → recheck loop, auto-resolve is delegated: the recheck carries the workflow's auto-resolve designation, and after a verified LGTM the threads it classified `Resolved` are resolved by the reviewer or, on handoff, by the orchestrator using the reported verified target set, each confirmed by a `review-threads.read` re-check of `resolved=true` with the reply confirmation and lightweight checks that recheck.md defines. Every thread the latest recheck did not classify `Resolved` remains open. A verified LGTM never auto-resolves a thread by itself. Do not automatically mark the PR ready, close panes other than the unused `ui-tester` pane above, merge the PR, or close the Issue.

Close the unused `ui-tester` pane once completion is confirmed with `herdr pane close <pane-id>`: the pane this workflow created that received no delegation is closed, and the closure is reported as one line. Keep a user-created pane, a pane that received a delegation, and every pane when the run fails or stops before completion; this is the only pane closure the workflow performs on its own, and `herdr tab close` and `herdr workspace close` are never used for it, because they would close delegated panes too.

Report the Issue, the origin of the used team specification (the [effective team profile](#team-profiles) or this run's approval), the target PR position (`対象 PR: 1/2` or `対象 PR: single`, with the base branch difference when the PR is stacked), base and work branches, Draft PR, latest commit, verification, review round count, separate Issue candidates if any, unresolved optional feedback or conversations, and every created pane's role and observed state, including the `ui-tester` participation line, its Draft PR re-judgment, the closure line when one was closed, and the latest head's evidence comment when one was posted or reused. When the PR's changed files include any skill, the report must also prompt the post-merge rollout: after merging, run the rollout procedure in [_docs/skill-distribution.md](../_docs/skill-distribution.md). Leave the panes available for inspection unless the user explicitly requests cleanup, except the unused `ui-tester` pane closed above.
