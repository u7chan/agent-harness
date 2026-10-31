---
name: herdr
description: Herdrの別ペインにいるコーディングエージェントへ作業を委譲する。Herdrの明示指定、またはHerdrという名前を挙げずに「別ペイン」への委譲・調査・プロンプト送信・エージェント間調整を依頼された場合に使う。HERDR_ENV=1が必要。
---

# Herdr

ペインとエージェントの操作には既存の`herdr` CLIを使う。ワークスペース、worktree、ペインを暗黙的に作成しない。

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

ペインIDとワークスペースIDはHerdrのJSON応答から解決し、推測しない。worktreeワークスペースの作成・削除は、ユーザーが明示的に依頼した場合だけ`herdr worktree create`と`herdr worktree remove`で行う。呼び出し元のチェックアウトを`--cwd "$PWD"`（または`--workspace "$HERDR_WORKSPACE_ID"`）で固定すること。固定しない呼び出しは、呼び出し元のcwdではなくクライアントでフォーカス中のワークスペースに従う。

## Caller pinning

委譲には`$HERDR_WORKSPACE_ID`と`$HERDR_PANE_ID`の両方が必要。いずれかが空、または`$HERDR_PANE_ID`のワークスペース接頭辞が`$HERDR_WORKSPACE_ID`と一致しない場合は、引数なしコマンドへフォールバックせず、fail closedで停止する。IDはHerdrのJSON応答だけから取得する。表示順、ラベル、モデル名、UIフォーカス、TUIで選択中のマシンから推測しない。

## Resolve the delegation target

この節を候補の解決、分岐、停止条件の正本とする。「別ペイン」「another pane」は、物理的に隣接するペインではなく、現在のHerdrサーバーにある呼び出し元のワークスペース内の別ペインを意味する。ペインではなくHerdrのworktreeワークスペースが指定された場合は[Worktree workspaces](#worktree-workspaces)に従う。これらはスキルに従うエージェント向けの運用上の安全策であり、技術的な強制境界を追加するものではない。

強い境界に必要な不変条件と責務分担は[Technical delegation boundary](references/technical-delegation-boundary.md)に定義されている。このスキルやラッパーから、それ以上の保証を推論しない。

### Server scope

ワークスペースID、ペインID、エージェント名はサーバー内でのみ一意であり、別サーバーにも同じ`w1:p1`、ワークスペースID、エージェント名が存在しうる。通常の委譲はサーバーをまたがない。範囲は呼び出し元ペインが継承した`herdr`コンテキストと、そのサーバー内の`$HERDR_WORKSPACE_ID`に限定される。

Herdr TUIで選択するマシンを変えても、CLIの対象サーバーは切り替わらない。ペイン内の`herdr`コマンドは、UIで選択されているマシンに関係なく、ペインが継承したセッション/socketのコンテキストを使い続ける。選択中のマシンから委譲先を解決しない。別マシンへの委譲は通常の委譲の対象外であり、現在のサーバー外を指す依頼は停止してユーザーに確認する。

### Candidate set

候補は次の応答だけから組み立てる。

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

`$HERDR_PANE_ID`自身は除外する。別ワークスペースのペインは[Worktree workspaces](#worktree-workspaces)で許可された辺の場合だけ候補となる。その場合も、混合インベントリではなく`herdr pane list --workspace <that-workspace-id>`または`herdr worktree create`の応答から解決する。全体の`workspace list`、引数なしの`pane list`や`agent list`、`pane layout`、`herdr machine list`、その他のマシン横断の統合一覧、UIフォーカスは読み取り専用の調査資料としてだけ使い、そこから委譲候補を選ばない。

明示された条件を満たすペインがちょうど1つの場合だけ選択する。0件、複数件、不明なペインメタデータ、JSON/APIエラーは同様に扱う。代替候補を推測せず、[When the requested agent is absent](#when-the-requested-agent-is-absent)へ進むかユーザーに確認する。

### Spatial neighbors

方向（「左」「右」「上」「下」または`left`/`right`/`up`/`down`）が指定された場合は、その方向だけを問い合わせる。

```bash
herdr pane neighbor \
  --pane "$HERDR_PANE_ID" \
  --direction <left|right|up|down>
```

方向を指定しない「隣」は、同じ起点から4方向すべてを問い合わせ、返された`neighbor_pane_id`を重複排除し、明示された条件を満たすペインがちょうど1つのときだけ使用する。複数残る場合は方向またはペインを質問する。各方向で返る隣接ペインは最大1つで、Herdrは距離・重なり・レイアウト順で解決する。

対象として読むのは`neighbor_pane_id`だけ。フィールドが存在しない、またはnullなら隣接ペインはない。`pane_id`（起点）へフォールバックしない。対象の解決に`--current`、`--pane`なしのneighbor、引数なしの`pane layout`を使わない。終了コードが非0、不正なJSON、ワークスペース不一致の場合は停止し、グローバル検索へフォールバックしない。

方向指定の隣接ペインが使用中で依頼条件に一致しなければ、上書きも無断の方向変更もせずユーザーに確認する。空の対話シェルであれば、依頼されたエージェントを実行できる。

## When the requested agent is absent

検索対象を現在のワークスペースより広げずに分岐する。

- 位置指定なし：`$HERDR_WORKSPACE_ID`内の既存の空の対話シェルを優先する。空きがあれば分割しない。
- 位置指定あり：解決した隣接ペインが空の対話シェルなら使用する。隣接ペインがなく、方向も指定されていない場合は、`$HERDR_PANE_ID`から明示的に分割して隣のペインを作る。指定方向に安全に作れない場合は別方向を推測せず、ユーザーに確認する。
- `$HERDR_WORKSPACE_ID`内に利用可能なペインがなければ、`$HERDR_PANE_ID`から明示的に分割する。

分割とエージェント起動で返るIDはすべてJSON応答から読む。起動後、委譲前に対話可能な状態と、ユーザー指定のprovider、model、thinking設定を検証する。不明な値を一致とみなさない。起動は[Pane operations](#pane-operations)に従う。「指定エージェントがいない」と「利用可能なペインがない」を同一視しない。エージェント不在時の標準動作が分割というわけではない。

## Multi-pane layout

1回の作業で複数の兄弟エージェントペインが必要な場合、場当たり的に分割せずレイアウト全体を計画する。

```bash
herdr/scripts/pane-layout.sh apply --count <panes> --label <team>
```

`plan --count <n> --area <WxH>`でHerdrを変更せずに同じグリッドをプレビューできる。
`apply`は`--count`個ちょうどのペインを作成し、セル順でIDを返す。定数、グリッド選定、タブ方針、失敗時の動作は[Pane layout](references/pane-layout.md)を参照する。

計画済みレイアウトに限り、次の2つの例外がある。

- 無関係な空のシェルを流用しない。プランナーは既存ペインを計画したセルへ移動できないため。単一ペインの委譲では[When the requested agent is absent](#when-the-requested-agent-is-absent)の再利用ルールを維持する。
- 現在のタブにチームが収まらないとプランナーが報告した場合は、確認なしで新しいタブを作成してよい。ワークスペースやworktreeの作成には引き続き明示的なユーザー依頼が必要。

## Async delegation

通常の委譲はfire-and-forgetで、`--wait`を使わない。既存エージェントへタスクを送り、後のターンで`herdr agent get`と`herdr agent read`を使って状態とターミナル出力を確認する。

親子間の直接的な結果返却には、次の薄いラッパーを使う。

```bash
herdr/scripts/parent-delegate-async.sh <child-pane> "<prompt>"
herdr/scripts/child-return-result.sh <direct-parent-pane> <completed|blocked> "<body>"
```

新しい親→子の委譲、および結果の返却を期待する追加タスクには、必ず親ラッパーを使う。[Resolve the delegation target](#resolve-the-delegation-target)に従って対象を解決し、エージェント名ではなく返されたペインIDを渡す。ラッパーも候補の成立条件の一部として扱う。ラッパーがない、実行されていない、非0で終了する、あるいはその辺を拒否すると予測できる場合、候補は無効。許可された辺で対象を解決し直すか`blocked`を報告する。ラッパー用プロンプトを手作業で再構築せず、生の`herdr agent prompt`、別ラッパー、`pane send-text`へフォールバックしない。通信失敗や結果不明の場合、状態を確認せずに再送しない。scope拒否と通信失敗は区別する。子ラッパー内部の生の`herdr agent prompt`は固定された返却経路であり、親→子で生のプロンプトを送る許可ではない。別Herdrサーバーへの委譲は、ユーザーが対象ペインを明示しても非対応なので停止する。

親ラッパーは呼び出し元自身のペインを検証し、子への辺を分類する（[Worktree workspaces](#worktree-workspaces)）。その後で、現在の`$HERDR_PANE_ID`、解決した表示名、子ラッパーの絶対パスをプロンプトへ追加する。子ラッパーは状態1つと自由形式の本文をそのペインへ返し、書き込みの直前に逆方向の同じスコープ検証を行う。拒否された辺では終了コード3で、stderrに`scope-reject: <reason>`を出し、対象には何も書き込まない。各委譲の辺には直接の親が必ず1つだけ存在する。ラッパーのプロトコル、表示名、失敗処理、worktreeルールは[Async delegation](references/async-delegation.md)を参照する。

ラッパーは引数と環境を検証し、既存の`herdr agent prompt`を実行して結果を伝播する。親ラッパーは親の表示名を解決するために読み取り専用の`herdr pane get`も1回呼ぶ。取得失敗時はプロンプト内でペインIDだけを使用する。ラッパーは待機、再試行、キューイング、状態永続化、Herdrリソース作成を行わない。

結果の返却待ちで親をブロックしない。返却は親ペインへプロンプトとして注入され、親がツール呼び出し中ならPiがsteeringとしてキューへ入れ、現在のアシスタントターンのツール呼び出し完了後に処理する。`sleep`によるポーリングのような長いフォアグラウンドコマンドで親を占有しない。ターンを終了して注入プロンプトに次のターンを開始させるか、フォアグラウンドコマンドを短く保つ。そうしなければ、キュー内の返却はコマンドの終了・タイムアウト・中断まで処理されない。

作業中の親への返却でエージェント種別に固有の問題が見つかった場合は、停止して再現手順を記録する。ラッパーへ待機やキューイングを追加しない。

## Worktree workspaces

委譲がワークスペース境界を越えられるのは、サーバー側状態または記録されたgrantが辺を許可する場合だけ。許可される辺は次の3種。

- `same-workspace`：送信元と送信先が同じワークスペース。
- `worktree-team`：`herdr workspace list`で両ワークスペースの`worktree.repo_root`が同じで、片方だけがリンク済みworktree（`worktree.is_linked_worktree`）である。元チェックアウトからリンク済みworktreeへの委譲と、worktreeから元チェックアウトへの返却が可能。2つのリンク済みworktree同士、または同じリポジトリの2つのチェックアウトは、`repo_root`が同じでも該当しない。
- `granted`：委譲スコープファイルに、両方向に適用される有効期限内の記録が存在する。形状ルールから導けない辺を人間が承認した場合は`herdr/scripts/scope-grant.sh`でgrantを記録・一覧・取消する。`--target-repo`は特定のワークスペースIDではなく、そのリポジトリの全ワークスペースにgrantを与える。記録はサーバー内でのみ一意なワークスペースIDをキーとし、ファイルはユーザー単位で共有される。そのため、同一ユーザーの別Herdrサーバーに同じIDのワークスペースペアがあっても記録上は適用されるが、サーバー間の委譲は引き続き非対応。

ラッパーは書き込み直前に`herdr/scripts/lib/scope.sh`で各辺を分類する。拒否時は終了コード3、stderrに`scope-reject: <reason>`を出し、対象に何も書かない。scope拒否は通信失敗と区別する。判断不能なものもすべて拒否する。例：`herdr workspace list`の失敗・不正な結果、サーバーに存在しないワークスペース、リポジトリ間の関係不明、呼び出し元自身のペイン。grantファイルは人間の意思の記録であって権限境界ではない。[Technical delegation boundary](references/technical-delegation-boundary.md)を参照する。

読み取り専用の探索（`herdr workspace list`、`herdr worktree list --cwd "$PWD"`、`herdr pane list --workspace <linked-workspace-id>`）は引き続き許可する。worktreeのライフサイクル操作は、ユーザーが明示的に依頼した場合に引き続き使用できる。

`herdr workspace create --cwd <path>`で作成したワークスペースにはworktree情報がないため、形状ルールから辺を導けない。[Workspaces without worktree information](references/async-delegation.md#workspaces-without-worktree-information)を参照する。

ユーザーがworktreeワークスペース内で自己完結するチームを依頼した場合は、[Worktree workspace teams](references/worktree-workspace-teams.md)に従って起動・調整する。
orchestrator-first構成では、親がworktreeを作成し、`worktree-team-start.sh`でそのルートペインにorchestratorをちょうど1つ起動し、worktree環境ブロックを渡す。その後orchestratorがチームを作成・起動する（[Orchestrator-first](references/worktree-workspace-teams.md#orchestrator-first)）。

### Scope intent and intended crossings

スコープガードの目的は、無関係なワークスペースやペインへの意図しない書き込みを防ぐことであり、意図した越境を一律に禁止することではない。`scope-reject`は、辺の検証を求めるための停止地点であって操作そのものの禁止ではない。また、ガードは[Technical delegation boundary](references/technical-delegation-boundary.md)でいう運用上の安全策であり、権限境界ではない。意図した越境は次のいずれかの経路で完了する。

1. 実際の状態と対象を照合する。`herdr workspace list`と`herdr pane list --workspace <workspace-id>`でワークスペースとペインを解決し、ユーザーが指定した対象と一致することを確認する。
2. 理由を記録し、grantを優先する。人間が`herdr/scripts/scope-grant.sh grant --source <workspace> --target <workspace>|--target-repo <path> --by <name> --task <issue-or-pr>`で辺を記録し、通常のラッパー経由で越境する。両ラッパーが書き込み直前にgrantを検証するため、これを優先経路とする。
3. ユーザー自身に実行してもらう。形状ルール上の許可された辺がなく、grantも適用されない場合、ユーザーが自分でチームを操作したい場合、または親が対象ワークスペースへ書き込んではならない場合は、[Fallback: user-started teams](references/worktree-workspace-teams.md#fallback-user-started-teams)のようにユーザーがコマンドを実行する。この場合の書き込み主体は人間となる。

拒否後に検証を迂回することは禁止。ワークスペースをまたぐ生の`herdr agent prompt`や`herdr agent start`、手で再構築したラッパープロンプトは越境経路ではない。「ユーザーが依頼した」は生のプロンプトを使う理由にはならず、その依頼は上記2または3の経路で実現する。

## Pane operations

明示的に依頼されたペイン操作の前に、現在のワークスペースを確認する。

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr pane get <pane-id>
```

エージェント起動時は`$HERDR_WORKSPACE_ID`にある既存の対話ペインを使い、責務に基づいた名前を付ける。利用できるペインがなければ、フォーカスを変えずに`$HERDR_PANE_ID`から分割する。返されたペインとエージェントのIDをJSONから読み、ペインIDに対して`--wait`なしでプロンプトを送る。

起動後、`herdr pane rename <pane-id> <name>`でペインラベルを同じ責務名に設定し、`herdr pane get <pane-id>`がその`label`を返すことを確認する。エージェント名とペインラベルは別物。手動でラベルを付けない場合、`show_agent_labels_on_pane_borders = true`では`codex`など検出されたエージェント種別が表示される。

## Rules

- 共有作業は現在のワークスペースとworktree内で行う。
- Herdrのworktreeワークスペースはユーザーの明示依頼がある場合だけ作成する。通常の独立ブランチでの作業は、現在のワークスペースとworktreeに留める（[Worktree workspaces](#worktree-workspaces)）。
- 明示依頼がない限り、ペインのクローズ、エージェントの強制終了、Herdrサーバーの停止、生のGit worktree管理を行わない。例外は1つだけ。`herdr-pi-issue-pr-workflow`は完了時に自身が作成し、一度も委譲していない`ui-tester`ペインを`herdr pane close <pane-id>`で閉じる（[herdr-pi-issue-pr-workflow](../herdr-pi-issue-pr-workflow/SKILL.md#completion)）。
- ワークスペース境界を越えてエージェントを直接起動したりプロンプトを送ったりしない。まず辺を分類するラッパーまたは`herdr/scripts/worktree-team-start.sh`を使い、`scope-reject`なら迂回や再試行をせず停止する（[Scope intent and intended crossings](#scope-intent-and-intended-crossings)）。
