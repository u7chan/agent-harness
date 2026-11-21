# Worktree workspace teams

Herdr の worktree ワークスペース内でチームを実行する手順。親ワークスペースがチームを直接起動するか、1 人の orchestrator を通して起動する（[Orchestrator-first](#orchestrator-first)）。`worktree-team` の辺（親チェックアウトからリンク済み worktree へ、およびその逆）は `herdr workspace list` の状態から導出され、委譲スコープのルールで許可される。チームを手作業で起動する方法は、ルールがカバーしないケースと、ユーザーがチームを直接操作したい場合のフォールバックとして残る。

スコープのルールは運用上の安全策であり、権限境界ではない（[`async-delegation.md`](async-delegation.md#workspace-and-worktree-ownership)、[Technical delegation boundary](technical-delegation-boundary.md)）。

## When to use it

ユーザーが、タスクごとに 1 つの Herdr worktree ワークスペース、専用ブランチ、専用ロールを持つタスク・パー・worktree のトポロジを求めた場合に使う。

通常の独立ブランチ作業では、このトポロジを提案しない。共有作業は現在のワークスペースと worktree に留める（[`herdr/SKILL.md`](../SKILL.md)）。

## Topology creation

ユーザーが明示的に依頼した場合、リポジトリの親ワークスペースから worktree ワークスペースを作成する。

```bash
herdr worktree create --cwd "$PWD" --branch <branch> [--no-focus]
```

`--cwd` は送信元チェックアウトを固定する。指定しない場合、呼び出しはクライアントでフォーカス中のワークスペースに従う（[Workspace and worktree ownership](async-delegation.md#workspace-and-worktree-ownership) 参照）。リンク済みワークスペース ID とそのルートペインは作成応答から読む。

```text
result.workspace.workspace_id        linked workspace ID
result.worktree.open_workspace_id    the same linked workspace ID
result.root_pane.pane_id             root pane, at an interactive shell
```

これらの ID を表示順、ラベル、後からの `worktree list` から推測しない。

宛先は worktree として作成する。そうすれば親とチームのワークスペースが、形状ルールから導出できる関係を共有する。`herdr workspace create --cwd <path>` で作った通常のワークスペースには worktree 情報がないため、辺を導出できない。[Workspaces without worktree information](async-delegation.md#workspaces-without-worktree-information) を参照する。

## Starting and coordinating the team

親ワークスペースから worktree ワークスペースへの辺が許可されている場合、親はチームを起動してプロンプトを送れる。

- `worktree-team` — 親ワークスペースと worktree ワークスペースが同じ `worktree.repo_root` を報告し、片方だけがリンク済み worktree である。`herdr worktree create` は新しいワークスペースを固定先のチェックアウトにリンクするため、これが通常のケースである。worktree への委譲と親への返却の両方をカバーする。
- `granted` — 形状ルールが導出しないペアについて、人間が先に辺を記録する。`--target-repo` はそのリポジトリの全ワークスペースをカバーするため、worktree ごとに繰り返す必要はない。

```bash
herdr/scripts/scope-grant.sh grant --source <parent-workspace> --target-repo <repo-root> --by <name> --task <issue-or-pr> [--ttl <seconds>]
```

同じリポジトリの兄弟 worktree、リポジトリの 2 つ目のチェックアウト、別サーバーの対象は拒否される。拒否された辺は終了コード 3 で `scope-reject: <reason>` を出し、何も書き込まない。再試行で回避せず、そのまま報告する。

### Orchestrator-first

この構成では、worktree を作成した起動元（starter）が、そのルートペインに orchestrator をちょうど 1 人起動する。その後 orchestrator がチームを作成・駆動し、starter とワークフローの親はチームのペインを作成しない。

starter には 2 つの経路がある。

- **経路 1**: `herdr-issue-pr-workflow` の親がキックオフゲートを通し、承認済みチームを起動する。orchestrator 自身の仕様はチームの承認対象ではなく、この経路でもプロファイルから解決する。
- **経路 2**: 別のペイン（Pi または Claude）がこのスキルだけを読んで起動する。このペインはキックオフゲートを通っていないため、承認済みチームも orchestrator の仕様も持たない。それでもハーネス別の仕様をその場で選ばず、プロファイルから解決する。この経路の orchestrator は、`launch:` 行の確認後に [Preflight](../../herdr-issue-pr-workflow/SKILL.md#preflight) と [Kickoff gate](../../herdr-issue-pr-workflow/SKILL.md#kickoff-gate) を通してチームを確定してから `Start the team` へ進む（[キックオフ用テンプレート](../../herdr-issue-pr-workflow/references/kickoff-task-template.md)）。

プロファイル解決の正本は [Pi Development Profiles](../../_docs/pi-development.md)、起動・`launch:` 行・報告の正本はこの節とする。同じ手順をキックオフテンプレートへ複製しない。

どちらの経路でも、starter は対象 worktree と同じ `repo_root` を持つ親チェックアウトのペインでなければならない（[Starting and coordinating the team](#starting-and-coordinating-the-team) の `worktree-team` 辺を導出できる側）。兄弟 worktree や 2 つ目のチェックアウトからの起動は形状ルールで拒否されるため、`herdr/scripts/scope-grant.sh` で辺を記録してから起動する。生の `herdr agent start` で境界を迂回しない。

1. [Topology creation](#topology-creation) のとおりに worktree を作成し、その JSON 応答からリンク済みワークスペース ID とルートペイン ID を保持する。
2. worktree 環境ブロックを含む orchestrator のタスクファイルを書く。タスクファイルにはハーネス別の仕様（Pi の provider/model/thinking、Claude の model/effort/permission_mode）も `launch:` 行も書かない。
3. starter のワークスペースから、プロファイルのロールを解決して orchestrator を起動する。

   ```bash
   herdr/scripts/worktree-team-start.sh <root-pane-id> <orchestrator-name> \
     --role orchestrator <task-file>
   ```

   この実行だけ別のプロファイルを使う場合は `--profile` を足す。指定したプロファイルが存在しない・不正な場合は `active` へフォールバックせず停止する。

   ```bash
   herdr/scripts/worktree-team-start.sh <root-pane-id> <orchestrator-name> \
     --role orchestrator --profile <name> <task-file>
   ```

   `--role` はプロファイルのロール名であり、タスク文面の `role: orchestrator` とは別物である。agent 名も単なるラベルで、ロール名と一致する必要はない。`--profile` を省略すると `active`、次に `default` を使う。`--resolver <path>` はモデル仕様リゾルバを差し替えるテスト・上級者向けのオプションで、絶対パスで指定する（start は変換せず `team-record.sh` へ渡す）。

   スクリプトは `team-record.sh resolve --only-role <role>` で仕様を解決し、共有ランチャー（`start-agent.sh`）を呼んで起動する。解決結果を stderr と委譲本文の末尾（返却指示の前）へ `launch:` 行として出す。Claude の場合はランチャーの `effective:` 行も同じ位置へ転記する。Pi の `effective:` 行はエージェント自身が出す。

   行の形式、`harness` と `spec` の接頭辞一致、複数行のときの正本は [Launch and effective lines](../../_docs/pi-development.md#launch-and-effective-lines)。starter は stderr の `launch:` 行を応答に含める。内容が曖昧なら停止する。

   プロファイルモードでは `profile` が使用したプロファイル名、`role` が `--role`、`spec_source=profile`、`origin` が team-record の `source` になる。

   プロファイルに orchestrator が無い初回はまだ起動できない。プロファイル解決の手順は [Pi Development Profiles](../../_docs/pi-development.md) を正本とし、`write` で追加するか、次の一度限りの明示モードで起動する。

   ```bash
   # write は全置換なので、保持する既存チームのロールもすべて渡す。
   scripts/pi-development/team-record.sh write --profile <name> \
     --pr-fix-shared-with-impl <true|false> \
     --role impl=<harness>:<...> \
     --role review=<harness>:<...> \
     --role pr-fix=<harness>:<...> \
     --role orchestrator=<harness>:<...>

   # プロファイルに orchestrator が無い場合の一度限りの明示モード（Pi）。
   herdr/scripts/worktree-team-start.sh <root-pane-id> <orchestrator-name> \
     --provider <provider> --model <model> --thinking <level> <task-file>

   # 同じ明示モード（Claude）。
   herdr/scripts/worktree-team-start.sh <root-pane-id> <orchestrator-name> \
     --harness claude --model <model> --effort <level> --permission-mode <mode> <task-file>
   ```

   明示モードはプロファイルを読まない。`--harness` の既定は `pi` で、Pi は `--provider`/`--model`/`--thinking`、Claude は `--model`/`--effort`/`--permission-mode` の完全な 3 値だけを受け付ける。ハーネスをまたぐ値や一部だけの 3 値は usage error である。「プロファイルに orchestrator が無い場合だけ」は規約であり、スクリプトで強制しない。starter は `launch: ... spec_source=explicit origin=explicit` を応答に含めて監査する。明示 3 値と `--role`、3 値の一部だけ、`--role` なしの `--profile` や `--resolver`、モード未指定はすべて usage error（終了コード 2）であり、何も起動しない。

   この起動が、starter による worktree ワークスペースへの唯一の `worktree-team-start.sh` 呼び出しである。経路 2 ではワークフローの親が同じ worktree へ別の orchestrator を追加しない。スクリプトのスコープ、起動、返却のルールはそのまま適用される。
4. starter は orchestrator の起動 spec を確認する。判定はハーネス別にする。Pi の orchestrator は起動後に `printf 'pi:%s/%s/%s\n' "$PI_PROVIDER" "$PI_MODEL" "$PI_REASONING_LEVEL"` を実行し、`launch:` の `spec` と照合する。`spec` は `pi:` 接頭辞を含み、`harness=pi` がその接頭辞と一致する。Claude の orchestrator は、`worktree-team-start.sh` が転記したランチャーの `effective:` 行の `requested=` を `launch:` の `spec` と照合する。`spec_source=profile` のときだけ `model` を保存済みの canonical 完全 ID と照合し、明示 alias の起動では canonical な `model` を今回の実効値として報告する。starter は補助として `herdr agent read <pane-id> --source visible` の footer を見てよいが、footer だけで一致とみなさない。一致しない、または取得できない場合は停止して報告する（[キックオフ用テンプレート](../../herdr-issue-pr-workflow/references/kickoff-task-template.md)）。
5. orchestrator は worktree ワークスペース内のチームを所有する。ペインの作成（`herdr/scripts/pane-layout.sh apply`）、エージェントの起動（共有ランチャー `herdr/scripts/start-agent.sh`）、タスクの委譲（`herdr/scripts/parent-delegate-async.sh`）を行う。チームロールの起動に `herdr agent start` を直接組み立てない。親は `impl`、`review`、`ui-tester` などのロールペインを事前に作ったり、それらのエージェントを起動したりしてはならない。チームごとに書き込み主体は 1 つである。

#### Worktree environment block

親は常にこのブロックを orchestrator に渡す。`worktree-team-start.sh` に渡すタスクファイルの本文に含める。

```text
workspace: <linked workspace ID>
pane: <root pane ID>
checkout: <worktree checkout path>
branch: <work branch>
base ref: <base ref the branch was created from>
base commit: <commit ID of that base ref>
```

- `workspace` と `pane` は Herdr の JSON 応答だけから取得する。`herdr worktree create` の応答（`result.workspace.workspace_id`、`result.root_pane.pane_id`）、または再オープン後の `herdr worktree open` の応答を使う。表示順、ラベル、フォーカス、後からの一覧から推測しない（[`herdr/SKILL.md`](../SKILL.md#caller-pinning)）。
- `checkout` と `branch` は、`herdr worktree list --cwd "$PWD"` のうち `open_workspace_id` がリンク済みワークスペースであるエントリから取得する。パスを自分で組み立てない。
- `base ref` と `base commit` は送信元チェックアウトで Git から読む。Herdr の状態からは読まない。`base commit` は `base ref` が解決するコミットである。

orchestrator はこのブロックを動作コンテキストとして使う。自身のワークスペースとペイン、チームが作業するチェックアウト、タスクの起点となるブランチと base である。該当する値は各チームタスクにも渡す。

この節の残りは、親が各ロールメンバーを自身で準備・起動する直接構成を説明する。orchestrator-first 構成では、その作業は上記のとおり orchestrator に属する。

何かを起動する前に、ロールごとに 1 つのペインと 1 つのタスクファイルを用意する。worktree のルートペインは作成応答から取得するため、追加ロールごとに分割し、分割応答から新しいペイン ID を読む。

```bash
herdr pane split --pane <root-pane-id> --direction right --cwd <worktree-path> --no-focus
```

タスク本文は先にファイルへ書き、空でないことを確認する。`herdr agent prompt` は空文字列を `empty_agent_prompt` で拒否し、存在しないファイルに対する `$(cat <task-file>)` はまさにその空文字列に展開される。

```bash
cat > <task-file> <<'TASK'
Goal: <what this role must deliver>
Acceptance: <how the result is verified>
Reporting: return the final status and body to the direct parent pane; comment on the pull request or issue when one exists
TASK
test -s <task-file>
```

親ワークスペースからチームメンバーを起動する場合は、辺の分類を含む `worktree-team-start.sh` を使う。スクリプトは内部で共有ランチャー `start-agent.sh` を呼び、起動そのものはランチャーが所有する。ワークスペースをまたがないチームロールは、worktree 内の orchestrator が `start-agent.sh` を直接使って起動し、rename と `parent-delegate-async.sh` を呼び出し元が行う。

```bash
# 親ワークスペースから（Pi）。辺の分類はスクリプトが行う。
herdr/scripts/worktree-team-start.sh <pane-id> <role> \
  --provider <provider> --model <model> --thinking <level> <task-file>

# 親ワークスペースから（Claude）。
herdr/scripts/worktree-team-start.sh <pane-id> <role> --harness claude \
  --model <model> --effort <level> --permission-mode <mode> <task-file>

# worktree 内のチームロール（ワークスペースをまたがない）。
herdr/scripts/start-agent.sh <pane-id> <role> \
  --spec <harness>:<...> \
  --profile <name|-> --role <role> \
  --spec-source <profile|explicit> --origin <explicit|active|default>
herdr pane rename <pane-id> <role>
herdr/scripts/parent-delegate-async.sh <pane-id> "$(cat <task-file>)"
```

`start-agent.sh` は引数検証と preflight、`herdr agent start --kind <harness>`、起動後の有界待機、Claude の `probe:`/`effective:` 行を所有する。`launch:` / `effective:` の形式と不変条件は [Launch and effective lines](../../_docs/pi-development.md#launch-and-effective-lines) を正本とする。rename とタスク委譲はランチャーの責務ではない。

`worktree-team-start.sh` は何よりも先に辺を分類し、共有ランチャーで起動し、エージェントが対話可能になるまでの有界待機、`herdr pane rename <pane-id> <role>`、最後に `parent-delegate-async.sh` 経由のタスク本文（直接の親への返却指示を追加する）を行う。起動、準備完了待機、rename のいずれかが失敗すると、プロンプトの前にコマンドが停止する。scope 拒否は終了コード 3 で終わる。プロンプトの失敗は通信失敗である。エージェントはペイン内で起動・rename されたままなので、隣に 2 人目を起動せず、そのペインを調べる（`herdr agent get`、`herdr agent read`）。エージェントのフラグは、個別の引数として渡す 1 行のトークンである。`herdr agent start` は複数行の AGENT_ARG を、何かが起動する前に拒否する。

```text
{"error":{"code":"invalid_agent_argument","message":"agent arguments cannot be encoded safely for the target shell"},"id":"cli:agent:start"}
```

上流は `herdr agent prompt` のファイル/stdin 入力を受け付けなかった（herdrdev/herdr#3367、2026-08-29 に not planned としてクローズ）。そのため本文は 1 つのシェル引数として届けなければならず、スクリプトはプロンプト呼び出し時にタスクファイルから展開し、エージェントのフラグは別の起動呼び出しに保つ。

### Fallback: user-started teams

辺が許可されない場合、ユーザーがチームを直接操作したい場合、または親が worktree ワークスペースへ書き込んではならない場合、上記のコマンドをユーザーに渡して実行してもらう。進行の所有もユーザーに移る。親はラッパーの返却を受け取らず、`gh` スキルを通して pull request や issue から結果を集める。

メンバーが親へ返却しない自己完結型チームでは、進捗、判断待ち、完了を 1 つの固定テンプレートで報告する。タスクの pull request へのコメントとして投稿し、pull request がまだない場合は issue へ投稿する。

```text
status: progress | decision-wait | completed
role: <role or agent name>
body: <what changed, or the question, in one to three lines>
```

`decision-wait` の報告は親またはユーザーへの質問である。回答は同じコメントスレッドへの返信として届き、チームはその返信を読むと続行する。親はフォールバックチームへ追加プロンプトを送らない。1 つのチームで 2 つのモードを混在させない。親がラッパー経由でチームを起動・調整するか、ユーザーが起動してチームが GitHub コメントで報告するかのどちらかである。

worktree ワークスペース内では、チーム内部の委譲は通常の同一ワークスペース委譲であり、ラッパーはそのペイン間で機能する。

## Cleanup

worktree ワークスペースは live なワークスペース ID で削除する。

```bash
herdr worktree remove --workspace <linked-workspace-id>
```

ワークスペースが閉じられている場合、`herdr worktree list --cwd "$PWD"` はその `open_workspace_id` を省略し、古いワークスペース ID での削除は `workspace_not_found` で失敗する。先に worktree を再オープンし、open 応答のワークスペース ID（新しい ID）で削除する。

```bash
herdr worktree open --cwd "$PWD" --path <worktree-path>
herdr worktree remove --workspace <reopened-workspace-id>
```

関係するワークスペースはリンク済みワークスペースだけではない。リポジトリにまだ開いているワークスペースがない場合、`herdr worktree create`（および `worktree open`）は送信元チェックアウト用のワークスペースも開く。チェックアウトパスにシェルペインが 1 つある状態である。作成応答はリンク済みワークスペースだけを返し、`worktree remove` は送信元ワークスペースを閉じない。送信元ワークスペースがこのタスクのために開かれ、ユーザーがもう必要としない場合は、リンク済みワークスペースの削除後に閉じる。

```bash
herdr workspace list
herdr workspace close <source-workspace-id>
```

`herdr workspace list` で、`worktree.is_linked_worktree` が `false` で、`worktree.checkout_path` が送信元チェックアウトであるエントリを特定する。リポジトリにすでに開いているワークスペースがあった場合、`create` はそれを再利用するため、閉じるものはなく、同じリポジトリの既存ワークスペースはこのタスクが閉じるものではない。リンク済み worktree ワークスペースが開いている間に送信元ワークスペースを閉じると `workspace_group_close_required` で失敗する。`herdr workspace close <source-workspace-id> --group` は送信元とそのリンク済み worktree ワークスペースをまとめて閉じるが、Git の worktree チェックアウトはディスクに残す。そのため上記の 2 段階の順序を使う。

パスによる削除は上流の依存である。herdr 0.9.0 の `herdr worktree remove` は `--workspace` だけを受け付け、`--path` は `unknown option: --path` で失敗する。[Technical delegation boundary](technical-delegation-boundary.md) の上流依存の節を参照する。

## Prohibitions

- 拒否された辺を、生のクロスワークスペース `herdr agent prompt` や `herdr agent start` で迂回しない。それはまさに境界文書が拒否したモデル準拠依存である。非準拠のモデルは、準拠モデルが停止する場面で成功してしまう。意図した越境は `herdr/scripts/scope-grant.sh` で grant として記録するか、ユーザーが実行する（[Fallback: user-started teams](#fallback-user-started-teams)）。生のプロンプトでは行わない。
- ユーザーが起動したフォールバックチームの作業を、そのワークスペースを直接対象にしてラッパー経路へ戻さない。親からフォールバックチームへプロンプトを送らない。
- チームが作業している間にワークスペースを閉じたり削除したりしない。
- 読み取り専用の探索は引き続き許可する。`herdr workspace list`、`herdr worktree list --cwd "$PWD"`、`herdr pane list --workspace <linked-workspace-id>`。
