# Async delegation

この参照は、Herdr の 2 つのヘルパースクリプトが使う小さなプロトコルを定義する。引数の数、受け付ける status 値、ペイン ID の構文、環境変数の検証、プロセスの終了動作の正本はスクリプトである。委譲先の解決、指定エージェントがいない場合の分岐、停止の判断ルールは [`herdr/SKILL.md`](../SKILL.md) にあり、この参照では重複して定義しない。

## Parent to child

親は自身の現在のペイン ID を `$HERDR_PANE_ID` で把握している必要がある。委譲前に [`herdr/SKILL.md`](../SKILL.md) の定義（委譲先の解決）に従って子ペイン ID を解決する。この参照が定めるのは、解決済みのペイン ID でラッパーが呼ばれた後の動作だけである。

```bash
herdr/scripts/parent-delegate-async.sh <child-pane> "<prompt>"
```

親ラッパーは引数を検証し、自身のワークスペースから子ペインへの辺を分類し（[Workspace and worktree ownership](#workspace-and-worktree-ownership) 参照）、待機せずに子へ `herdr agent prompt` を 1 回送る。プロンプトには現在のペイン ID、その表示名、子ヘルパーの絶対パスを追加する。

```text
Direct parent pane for result return: <pane-id> (<display-name>)
```

表示名は読み取り専用の `herdr pane get` を 1 回呼んで解決し、ペインの境界表示と一致させる。手動ラベルを優先し、なければ検出されたエージェント種別を使う。取得に失敗した場合、またはどちらのフィールドもない場合、行はペイン ID だけを保持する。ヘルパーの呼び出しには常に生のペイン ID を渡す。子はその正確なヘルパーパスで最終回答を返せる。

```bash
"<absolute-child-helper-path>" "<direct-parent-pane>" completed "<body>"
```

子が親の判断や入力なしに続行できない場合は `blocked` を使う。

```bash
"<absolute-child-helper-path>" "<direct-parent-pane>" blocked "<reason and required input>"
```

本文は自由形式のテキストで、1 つのシェル引数として渡す。空白や改行を含む場合は引用符で囲む。親には次の形式で届く。

```text
status: completed|blocked
body:
<free-form body>
```

子は親を探索したり推測したりしない。委譲プロンプトに含まれるペイン ID だけを使う。親ラッパーは呼び出し元が指定した返却先を受け付けない。子ヘルパーは、その直接の親ペインへ生の `herdr agent prompt` を 1 回送って返却する。

返却経路は委譲経路と同じルールを逆方向に適用する。子ヘルパーはプロンプト送信前に `$HERDR_WORKSPACE_ID` から直接の親ペインへの辺を分類するため、ルール上許可されない返却は対象ペインへ何も書き込まない。

## Display names

ペイン境界に表示される名前は `label ?? agent kind` の順で解決する。

- `herdr pane get <pane-id>` はペインの JSON を返す。`result.pane.label` は `herdr pane rename` でラベルを設定した場合だけ存在する。未設定のラベルは JSON から省略され、null にはならない。`result.pane.agent` は `pi` や `codex` など、検出されたエージェント種別である。
- `herdr pane list --workspace <workspace-id>` はワークスペース内の全ペインについて同じフィールドを持つ。
- `herdr agent get <target>` はラベルを含まない。表示名の解決にはペインのコマンドを使う。

子が自身のペインでユーザーに返却先を報告する場合は、委譲プロンプトに埋め込まれた表示名（例：`wG:p1 (bob)`）を使い、ヘルパースクリプトには生のペイン ID を渡す。

## Direct edges

各委譲の辺には、直接の親ペインが 1 つだけ存在する。

```text
A -> B -> D
```

D は B へ返却し、B は D の結果を分類または要約した後に A へ返却する。並列作業では、各子は自身を委譲したエージェントのペインへ返却する。

```text
C -> E
C -> F
```

E と F はどちらも C へ返却する。グローバルな親ツリー、fan-out の返却先、試行識別子、終端マーカー、状態ファイルは存在しない。

## State and failure handling

`parent-delegate-async.sh` と `child-return-result.sh` は、エージェントが idle や done になるまで待機しない。プロンプト送信後、親は既存の CLI 状態とターミナル出力を後のタイミングで確認する。

```bash
herdr agent get <agent-or-pane>
herdr agent read <agent-or-pane> --source recent-unwrapped --lines 200
```

idle または working の親は、既存の `agent prompt` 操作で返却を受け取れる。ラッパーは配信をもってタスク完了とはみなさず、親が busy の場合の再試行やキューを実装しない。特定のエージェント種別が working 中に返却を受け取れない場合は、再現手順を添えて停止し、その挙動を別途追跡する。

返却は wake-up でもある。注入されたプロンプトとして届き、idle な親は次のターンとして処理する。親がツール呼び出しを実行中の場合、Pi はそのプロンプトを steering としてキューに入れ、現在のアシスタントターンがそれらの呼び出しを終えた後にだけ届ける。そのため、`sleep` ベースのポーリングのような長いフォアグラウンドコマンドは、終了するかツールのタイムアウトが発火するか人間が中断するまで、すべての返却を遅らせる。ペインをブロックせずに返却を待つこと。ターンを終了するか、フォアグラウンドコマンドを短く保つ。

ラッパーは失敗を区別して観測できる。`parent-delegate-async.sh` では、不正な引数、`HERDR_ENV=1` の欠落、`herdr` 実行ファイルの欠落、子ペインの scope 拒否がプロンプト送信前に発生するため、子には何も届かない。`child-return-result.sh` では、不正な引数、`HERDR_ENV=1` の欠落、`herdr` 実行ファイルの欠落、直接の親ペインの scope 拒否がプロンプト送信前に発生するため、直接の親には何も届かない。終了コード 2 は使用法エラー、1 は検証エラー、3 は scope 拒否で、stderr に `scope-reject: <reason>` を出す。

ラッパー自身の `herdr agent prompt` 呼び出しで観測された非 0 終了は通信失敗である。親ヘルパーはその非 0 終了を伝播し、子への配信は未確認となる。子ヘルパーも同様に非 0 終了を伝播し、直接の親への配信は未確認となる。

不明な結果は、観測された非 0 終了とは区別する。不明な結果から、どちらかのヘルパーの終了状態や宛先への配信成否を推測しない。ラッパーは再送しない。分類と復旧の判断は [`herdr/SKILL.md`](../SKILL.md) に従う。プロンプトの送信は、子が完了した証拠ではない。

## Workspace and worktree ownership

同じ成果物を編集するエージェントは、現在の Herdr ワークスペースと worktree を共有する。委譲はそれを必須としない。サーバー側の状態または記録された grant が許可する場合、辺はワークスペース境界を越えられる。両ラッパーは書き込み直前に `scripts/lib/scope.sh` で辺を分類し、2 つのワークスペース ID と live な `herdr workspace list` の状態だけを使う。許可される辺は次のとおり。

| Edge | Condition |
| --- | --- |
| `same-workspace` | 送信元と送信先が同じワークスペース |
| `worktree-team` | 両ワークスペースの `worktree.repo_root` が同じで、片方だけがリンク済み worktree。親チェックアウトからリンク済み worktree へ、リンク済み worktree から親チェックアウトへ到達できる |
| `granted` | 委譲スコープファイルの有効期限内の記録が、ワークスペースペアまたは対象リポジトリをカバーする |

同じリポジトリの 2 つのリンク済み worktree（兄弟）、同じリポジトリの 2 つのチェックアウト、無関係なリポジトリ、worktree 情報を持たないワークスペースは拒否される。grant は両方向に有効。呼び出し元自身のペインは、同一ワークスペースでもワークスペースをまたぐ場合でも常に拒否する。

その他の結果はすべて拒否とする。分類器が判断できない結果も含む。

| Reason | Meaning |
| --- | --- |
| `self-pane` | 対象ペインが呼び出し元自身のペイン |
| `workspace-list-failed` | `herdr workspace list` が失敗 |
| `workspace-list-invalid-json` | 応答が利用可能な状態ではない |
| `unknown-workspace` | 送信元または送信先のワークスペースがその状態に存在しない |
| `repo-mismatch` | 導出可能なリポジトリ関係がない |
| `sibling-worktrees` | 同じリポジトリで、両方がリンク済み worktree |
| `duplicate-checkout` | 同じリポジトリで、どちらもリンク済み worktree ではない |
| `grant-expired` | カバーする grant はあるが期限切れ |
| `scope-file-invalid` | スコープファイルは存在するが解析できない |
| `scope-file-unavailable` | `HERDR_SCOPE_FILE`、`XDG_CONFIG_HOME`、`HOME` のいずれもパスを解決できない |
| `classify-failed` | 分類器が判定を返さない |

拒否はプロンプト送信前に終了コード 3 で stderr に `scope-reject: <reason>` を出し、対象ペインには何も届かない。そのため拒否は通信失敗と区別できる。ラッパー自身の `herdr agent prompt` 呼び出しで観測された非 0 終了は通信失敗であり、scope 拒否ではない。不正なスコープファイルは形状ルールへフォールバックせず fail closed する。

grant は、形状ルールから導けない辺に対する人間の記録である。`--by` は必須で、各記録は id、送信元ワークスペース、送信先ワークスペースまたは対象リポジトリルート、タスク参照、grant した名前、作成日時と有効期限（`--ttl` がなければ無期限）を保持する。

```bash
herdr/scripts/scope-grant.sh grant --source <workspace> --target <workspace> --by <name> [--task <ref>] [--ttl <seconds>]
herdr/scripts/scope-grant.sh grant --source <workspace> --target-repo <path> --by <name> [--task <ref>] [--ttl <seconds>]
herdr/scripts/scope-grant.sh list
herdr/scripts/scope-grant.sh revoke <grant-id>
```

ファイルは `${HERDR_SCOPE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/delegation-scope.json}` に置かれ、モード 0600 で書き込まれる。`grant` は記録を 1 件追加して id を表示し、`list` は grant ごとにタブ区切りで 1 行表示し、`revoke` は id で 1 件削除する。不正なファイルは報告され、決して書き換えられない。grant はワークスペース ID で照合され、ワークスペース ID はサーバー内でのみ一意だが、スコープファイルはユーザー単位で共有される。そのため grant は、同一ユーザーの別 Herdr サーバーにある同じ ID のワークスペースペアもカバーする。サーバー間の委譲は対象外なので、このファイルはサーバー単位ではなくユーザー単位の状態として扱う。このファイルは人間の意思の記録であり、偽造不可能な capability ではない（エージェントプロセスが直接読み書きできる）。したがってこのスコープは運用上の安全策であり、強制境界ではない（[Technical delegation boundary](technical-delegation-boundary.md) 参照）。

拒否された辺を、生のクロスワークスペース `herdr agent prompt` や `herdr agent start` で回避しない。その迂回は [Technical delegation boundary](technical-delegation-boundary.md) が拒否したモデル準拠依存である。非準拠のモデルは、準拠モデルが停止する場面で成功してしまう。拒否は意図しない書き込みを止めるものであり、意図した越境を禁止するものではない。越境は grant として記録され、両ラッパーが書き込み直前に確認するか、[Fallback: user-started teams](worktree-workspace-teams.md#fallback-user-started-teams) のようにユーザーが実行する。「ユーザーが依頼した」は生のプロンプトを使う理由にならない。worktree ワークスペースの読み取り専用探索は引き続き許可される。

worktree のライフサイクルコマンドは引き続き利用でき、委譲は行わない。

```bash
herdr workspace list
herdr worktree create --cwd "$PWD" --branch <branch-name>
```

`worktree create`、`open`、`list` では `--cwd`（または `--workspace`）で送信元チェックアウトを固定する。固定しない場合、送信元は呼び出し元の cwd や `$HERDR_WORKSPACE_ID` ではなくクライアントでフォーカス中のワークスペースに従うため、固定しない呼び出しは別のリポジトリに作用しうる。フォーカス中のワークスペース自体がリンク済み worktree の場合、`worktree create` と `worktree open` は `linked_worktree_source` で失敗し、`worktree list` は送信元をその worktree の親リポジトリとして解決する。

実際のワークスペース ID は作成応答から解決する。削除するのはリンク済み worktree ワークスペースだけとし、対応する Herdr コマンドを使う。

```bash
herdr worktree list --cwd "$PWD"
herdr worktree open --cwd "$PWD" --path <worktree-path>
herdr worktree remove --workspace <linked-workspace-id>
```

ヘルパースクリプトはワークスペース、worktree、タブ、ペインを作成・共有・削除しない。呼び出し元は委譲前にワークスペースのトポロジを明示的に確立する必要がある。`scripts/worktree-team-start.sh` は同じスコープルールの下で既存の worktree ペインにチームメンバーを起動してプロンプトを送り、[Worktree workspace teams](worktree-workspace-teams.md) がそのトポロジを扱う。

### Workspaces without worktree information

`herdr workspace create --cwd <path>` で作成したワークスペースは worktree ワークスペースではない。`herdr workspace list` は `worktree` エントリを返さないため、`repo_root` は `-` に解決され、形状ルールはどちらの方向にも辺を導けない。そのような辺は grant がカバーするまで `reject:repo-mismatch` に分類される。worktree 情報を持たないワークスペースが委譲に関与する場合は、worktree にするか、その辺をカバーする grant を記録する。

- ユーザーには worktree として作成するよう案内する（`herdr worktree create --cwd "$PWD" --branch <branch>`）。そうすれば `worktree-team` の辺がサーバー状態から導出され、1 つの `--target-repo` grant がそのリポジトリの全 worktree をカバーする。ワークスペースや worktree の作成には、引き続きユーザーの明示的な依頼が必要。
- 通常のワークスペースとの間で委譲するには、両方のワークスペース ID を使ったペア grant を記録する（`herdr/scripts/scope-grant.sh grant --source <workspace> --target <workspace> --by <name> --task <issue-or-pr>`）。リポジトリの知識は不要で、辺を両方向にカバーする。`--target-repo` grant も、通常のワークスペースを `--source` にし、相手側の `repo_root` を `--target-repo` にすれば同じ辺をカバーする（`--source <plain-workspace> --target-repo <counterpart-repo-root>`）。分類器が相手側の報告する `repo_root` に対して grant を両方向で照合するためである。逆の形（リポジトリ側のワークスペースを `--source` にする）はカバーしない。通常のワークスペースは照合対象の `repo_root` を報告しないからである。
- grant は指定したワークスペース ID に紐づき、live に照合される。ワークスペースを閉じて作り直すと新しい ID が報告され、保存済みの grant はカバーしない。grant を記録し直すか、ワークスペースを worktree として作成する。これはペア grant と、再作成したワークスペースを `--source` にする `--target-repo` grant の両方に当てはまる。
