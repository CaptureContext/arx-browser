# Glossary: Japanese (ja)

Translators of Arx into Japanese use these terms. A term here wins over any other choice.

## Language rules

- Address: polite style (です・ます) in sentences, with no pronoun for the user, as Apple's Japanese macOS and Safari do ("プライベートウインドウを使用することを忘れていた場合は、ブラウズ履歴を消去できます。"). Buttons and menu items are short noun or verb forms without ます (「タブを固定」「閉じる」「キャンセル」). Verified: https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac
- Capitalization: not applicable. Latin-script names keep their own casing (Arx, Peek, iCloud, Touch ID, Split View, Mission Control, Dock, Finder).
- Spacing: Apple's Japanese puts no space between Japanese and Latin words or digits ("MacのSafari", "Safariの設定", "Command＋F", "Dockにしまいます"). Write "Arxを終了", "iCloudキーチェーン", "JavaScriptコンソール". Google's Chrome help puts spaces between katakana words ("シークレット モード"); Arx follows Apple and writes them without a space ("シークレットモード"), except in the product name "Chrome ウェブストア" as Google writes it. Verified: https://support.apple.com/ja-jp/guide/safari/cpsh003/mac
- Punctuation: full-width 、。：（）！？ in Japanese text. Quote UI names and other quoted text with 「」 (nested 『』), never "" or ''. Menu paths use full-width ＞ with no spaces: 「表示」＞「サイドバーを表示」. Where the English source uses › in a path, write ＞.
- Ellipsis: a single "…" (U+2026) directly after the word, as in English (プリント…, 設定…). Never "..." and never "・・・".
- Window is ウインドウ (Apple's spelling, with イ), never ウィンドウ. Folder is フォルダ, User Guide is ユーザガイド, Developer is デベロッパ (Apple's long-vowel-free spellings).
- Plural categories: other only. Japanese has no plural forms; Tab and Tabs are both タブ. Write counts as "%lld個のタブ" / "%lldタブ" with the number directly before the counter.
- macOS Spaces: Apple calls them 操作スペース (Mission Control keeps its English name; the bar is "Spacesバー"). Verified: https://support.apple.com/ja-jp/guide/mac-help/mh14112/mac
- Arx space: スペース, because it is the short, established loanword and stays distinct from Apple's compound 操作スペース; macOS Spaces must always be written 操作スペース, never bare スペース.
- Kanji vs. katakana: follow Apple. Copy/Paste in menus are コピー/ペースト (Apple's support pages also say 切り取り/貼り付け in prose; menus say カット/ペースト). Import/Export are 読み込む/書き出す.
- Keep it short: Japanese UI is compact; drop particles where Apple does in labels (「履歴を消去」, not 「履歴を消去します」).

## Terms

| English | Translation | Kind | Status | Check | Note |
| --- | --- | --- | --- | --- | --- |
| File | ファイル | menu | verified | no | menu bar title; https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac |
| Edit | 編集 | menu | standard | no | menu bar title |
| View | 表示 | menu | verified | no | menu bar title; also the verb "show" |
| History | 履歴 | menu | verified | no | Safari menu bar title |
| Window | ウインドウ | menu | verified | no | menu bar title; Apple spelling ウインドウ |
| Help | ヘルプ | menu | standard | no | menu bar title |
| Services | サービス | menu | standard | yes | app menu |
| About Arx | Arxについて | menu | standard | yes | macOS pattern "<App>について" |
| Hide Arx | Arxを非表示 | menu | standard | yes | macOS pattern "<App>を非表示" |
| Hide Others | ほかを非表示 | menu | standard | yes | app menu |
| Show All | すべてを表示 | menu | standard | yes | app menu |
| Quit Arx | Arxを終了 | menu | standard | yes | macOS pattern "<App>を終了" |
| Undo | 取り消す | menu | standard | no | Edit menu; menu shows "取り消す"; 102650 page also says 取り消し |
| Redo | やり直す | menu | standard | no | Edit menu |
| Cut | カット | menu | standard | no | Edit menu; prose may say 切り取り |
| Copy | コピー | menu | verified | no | Edit menu; https://support.apple.com/ja-jp/102650 |
| Paste | ペースト | menu | standard | no | Edit menu; prose may say 貼り付け |
| Paste and Match Style | ペーストしてスタイルを合わせる | menu | verified | yes | https://support.apple.com/ja-jp/102650 |
| Select All | すべてを選択 | menu | standard | yes | Edit menu |
| Find | 検索 | menu | verified | no | Edit menu submenu; https://support.apple.com/ja-jp/102650 |
| Use Selection for Find | 選択部分を検索に使用 | menu | standard | yes | Edit ＞ 検索 |
| Jump to Selection | 選択部分へジャンプ | menu | standard | yes | Edit ＞ 検索 |
| Spelling and Grammar | スペルと文法 | menu | verified | yes | https://support.apple.com/ja-jp/102650 |
| Show Spelling and Grammar | スペルと文法を表示 | menu | standard | yes | |
| Check Document Now | 書類を今すぐチェック | menu | standard | yes | |
| Check Grammar With Spelling | スペルチェックと同時に文法をチェック | menu | standard | yes | |
| Correct Spelling Automatically | スペルを自動的に修正 | menu | standard | yes | |
| Substitutions | 自動置換 | menu | standard | yes | Edit submenu |
| Smart Links | スマートリンク | menu | standard | yes | |
| Transformations | 変換 | menu | standard | no | Edit submenu |
| Make Upper Case | 大文字にする | menu | standard | yes | |
| Make Lower Case | 小文字にする | menu | standard | yes | |
| Capitalize | 先頭を大文字にする | menu | standard | yes | |
| Minimize | しまう | menu | standard | no | Window menu item; prose says 最小化 (https://support.apple.com/ja-jp/102650) |
| Zoom | 拡大/縮小 | menu | standard | no | Window menu (window zoom) |
| Bring All to Front | すべてを手前に移動 | menu | standard | yes | Window menu |
| Enter Full Screen | フルスクリーンにする | menu | standard | yes | View menu |
| Exit Full Screen | フルスクリーンを解除 | menu | standard | yes | View menu |
| Full Screen | フルスクリーン | platform | verified | yes | https://support.apple.com/ja-jp/guide/mac-help/mh14112/mac |
| Zoom In | 拡大 | menu | standard | no | Safari View menu |
| Zoom Out | 縮小 | menu | standard | no | Safari View menu |
| Actual Size | 実際のサイズ | menu | standard | yes | Safari View menu |
| Reload Page | ページを再読み込み | menu | standard | yes | Safari View menu |
| Reload | 再読み込み | browser | verified | no | 「プライバシー保護を緩和して再読み込み」 on https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac |
| Stop Loading | 読み込みを停止 | menu | unverified | yes | Safari's exact View menu wording not confirmed |
| Print… | プリント… | menu | verified | yes | Apple says プリント, not 印刷; https://support.apple.com/ja-jp/102650 |
| Page Setup… | ページ設定… | menu | standard | yes | File menu |
| Save Page As… | ページを別名で保存… | menu | standard | yes | Safari pattern 別名で保存… |
| Open File… | ファイルを開く… | menu | standard | yes | File menu |
| Close Window | ウインドウを閉じる | menu | standard | yes | File menu |
| Close Tab | タブを閉じる | menu | standard | yes | Safari File menu |
| New Window | 新規ウインドウ | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac |
| New Tab | 新規タブ | menu | verified | yes | 「新規タブボタン」 on https://support.apple.com/ja-jp/guide/safari/sfri11576/mac |
| New Private Window | 新規プライベートウインドウ | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac |
| New Incognito Window | 新規シークレットウインドウ | browser | decided | yes | Apple's 新規…ウインドウ pattern with Chrome's シークレット; Chrome writes 新しいシークレット ウインドウ |
| Incognito | シークレットモード / シークレット | browser | verified | yes | Chrome: シークレット モード; Apple style, no space; https://support.google.com/chrome/answer/95464?hl=ja |
| Private window | プライベートウインドウ | platform | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac |
| Private Browsing | プライベートブラウズ | platform | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrw1069/mac |
| Reopen Closed Window | 閉じたウインドウを再度開く | browser | unverified | yes | Chrome's Japanese wording not confirmed |
| Recently Closed | 最近閉じた項目 | menu | verified | yes | 「履歴」＞「最近閉じた項目」; https://support.apple.com/ja-jp/guide/safari/sfri11576/mac |
| Show All History | すべての履歴を表示 | menu | standard | yes | Safari History menu |
| Clear History… | 履歴を消去… | menu | standard | yes | Safari History menu |
| Show Next Tab | 次のタブを表示 | menu | standard | yes | Safari Window menu |
| Show Previous Tab | 前のタブを表示 | menu | standard | yes | Safari Window menu |
| Duplicate Tab | タブを複製 | menu | standard | yes | |
| Pin Tab | タブを固定 | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrw0495694f/mac |
| Unpin Tab | タブを固定解除 | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrw0495694f/mac |
| Mute Tab | タブを消音 | browser | unverified | yes | Safari says 消音 for tab audio as far as known; not confirmed |
| Unmute Tab | タブの消音を解除 | browser | unverified | yes | pairs with Mute Tab |
| Move Tab to New Window | タブを新しいウインドウに移動 | menu | verified | yes | note 新しい, not 新規; https://support.apple.com/ja-jp/guide/safari/sfri11576/mac |
| Merge All Windows | すべてのウインドウを結合 | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/ibrwbb6e21e4/mac |
| Developer Tools | デベロッパーツール | browser | standard | yes | Chrome: デベロッパー ツール; Apple style, no space |
| Inspect Element | 要素の詳細を表示 | menu | standard | yes | Safari context menu |
| JavaScript Console | JavaScriptコンソール | browser | standard | yes | no space |
| View Page Source | ページのソースを表示 | browser | standard | yes | |
| Keyboard Shortcuts | キーボードショートカット | platform | verified | yes | https://support.apple.com/ja-jp/guide/safari/cpsh003/mac |
| Check for Updates… | アップデートを確認… | menu | standard | yes | |
| Share… | 共有… | menu | standard | yes | |
| Tab | タブ | platform | verified | no | Safari; also the Tab key (Tabキー) |
| Tabs | タブ | platform | verified | no | no plural form |
| Window | ウインドウ | platform | verified | no | Apple spelling ウインドウ |
| Tab group | タブグループ | platform | standard | yes | Safari guide: 「タブをグループ化する」 |
| Favorites | お気に入り | platform | verified | yes | https://support.apple.com/ja-jp/guide/safari/welcome/mac |
| Favorite | お気に入り | platform | verified | yes | |
| Bookmarks | ブックマーク | platform | verified | yes | |
| Bookmark | ブックマーク | platform | verified | yes | noun and verb (ブックマークする) |
| Add Bookmark | ブックマークを追加 | menu | standard | yes | Safari menu adds … when it opens a dialog |
| History | 履歴 | platform | verified | no | browsing history: ブラウズ履歴 |
| Downloads | ダウンロード | platform | verified | no | |
| Download | ダウンロード | platform | verified | no | noun and verb |
| Picture in Picture | ピクチャ・イン・ピクチャ | platform | standard | yes | Apple writes it with ・ |
| Split View | Split View | platform | verified | yes | kept in English; https://support.apple.com/ja-jp/guide/mac-help/mh14112/mac |
| Full Disk Access | フルディスクアクセス | platform | verified | yes | https://support.apple.com/ja-jp/guide/mac-help/mchlccb25729/mac |
| Privacy & Security | プライバシーとセキュリティ | platform | verified | yes | https://support.apple.com/ja-jp/guide/mac-help/mchlccb25729/mac |
| System Settings | システム設定 | platform | verified | yes | |
| Settings | 設定 | platform | verified | no | 「Safari」＞「設定」 |
| Settings… | 設定… | menu | standard | yes | app menu item |
| General | 一般 | platform | verified | no | Settings tab |
| Appearance | 外観 | platform | standard | no | |
| Advanced | 詳細 | platform | verified | no | 「詳細」パネル; https://support.apple.com/ja-jp/guide/safari/cpsh003/mac |
| Extensions | 機能拡張 | platform | verified | yes | https://support.apple.com/ja-jp/guide/safari/welcome/mac |
| Extension | 機能拡張 | platform | verified | yes | |
| Passwords | パスワード | platform | verified | no | Safari tab and app; https://support.apple.com/ja-jp/guide/passwords/welcome/mac |
| Apple Passwords | パスワード / 「パスワード」アプリ | platform | verified | yes | app name is パスワード; in sentences 「パスワード」アプリ or パスワードアプリ |
| Keychain | キーチェーン | platform | verified | yes | iCloudキーチェーン |
| Keychain Access | キーチェーンアクセス | platform | verified | yes | https://support.apple.com/ja-jp/guide/keychain-access/welcome/mac |
| Profile | プロファイル | platform | verified | yes | 「プロファイルを作成する」 |
| Profiles | プロファイル | platform | verified | yes | |
| Sidebar | サイドバー | platform | verified | yes | |
| Show Sidebar | サイドバーを表示 | menu | standard | yes | Safari View menu |
| Hide Sidebar | サイドバーを非表示 | menu | standard | yes | Safari View menu |
| Toggle Sidebar | サイドバーの表示/非表示を切り替える | browser | decided | yes | Apple's 表示／非表示を切り替え pattern (https://support.apple.com/ja-jp/102650) |
| Reader | リーダー | platform | verified | yes | 「リーダーを開く」; https://support.apple.com/ja-jp/guide/safari/cpsh003/mac |
| Reading Mode | リーディングモード | browser | verified | yes | Chrome: リーディング モード; https://support.google.com/chrome/answer/14218344?hl=ja |
| Reading List | リーディングリスト | platform | verified | yes | |
| Website | ウェブサイト | platform | verified | no | |
| Websites | ウェブサイト | platform | verified | no | Safari Settings tab |
| Site | サイト | browser | verified | no | Chrome |
| Site Settings | サイトの設定 | browser | verified | yes | https://support.google.com/chrome/answer/114662?hl=ja |
| Permissions | 権限 | browser | verified | no | Chrome: サイトの権限 |
| Allow | 許可 | ui | standard | no | button |
| Don't Allow | 許可しない | ui | standard | yes | Apple permission button |
| Always Allow | 常に許可 | ui | standard | yes | |
| Allow Once | 1回のみ許可 | ui | unverified | yes | Chrome says 今回のみ許可; Apple's wording not confirmed |
| Ask | 確認 | ui | standard | no | permission option: 確認する |
| Block | ブロック | ui | standard | no | |
| Camera | カメラ | platform | standard | yes | |
| Microphone | マイク | platform | standard | yes | |
| Location | 位置情報 | platform | verified | no | Chrome site setting; Apple's service is 位置情報サービス |
| Notifications | 通知 | platform | verified | no | |
| Cookies | Cookie | browser | verified | yes | kept in English; 「サードパーティ Cookie」 in Chrome |
| Cache | キャッシュ | browser | standard | yes | |
| Clear Cache | キャッシュを消去 | browser | standard | yes | |
| Clear History | 履歴を消去 | browser | verified | yes | 「ブラウズ履歴を消去する」 |
| Browsing data | 閲覧履歴データ | browser | standard | yes | Chrome: 閲覧履歴データを削除 |
| Autofill | 自動入力 | platform | standard | yes | Safari AutoFill |
| Passkey | パスキー | platform | verified | yes | https://support.apple.com/ja-jp/guide/passwords/welcome/mac |
| Passkeys | パスキー | platform | verified | yes | |
| Sign in | サインイン | ui | standard | no | verb: サインインする |
| Sign-in | サインイン | ui | standard | no | |
| Sign Out | サインアウト | ui | standard | yes | |
| Account | アカウント | ui | standard | no | |
| iCloud | iCloud | platform | verified | yes | never translated |
| Touch ID | Touch ID | platform | standard | yes | never translated |
| Mission Control | Mission Control | platform | verified | yes | kept in English; https://support.apple.com/ja-jp/guide/mac-help/mh14112/mac |
| Spaces (macOS) | 操作スペース | platform | verified | yes | never bare スペース; https://support.apple.com/ja-jp/guide/mac-help/mh14112/mac |
| Desktop | デスクトップ | platform | verified | no | |
| Dock | Dock | platform | verified | yes | kept in English |
| Finder | Finder | platform | verified | yes | kept in English |
| Menu bar | メニューバー | platform | verified | yes | |
| Language & Region | 言語と地域 | platform | standard | yes | |
| Translate | 翻訳 | platform | verified | no | 「ウェブページを翻訳する」 |
| Translation | 翻訳 | platform | verified | no | |
| Default browser | デフォルトのWebブラウザ | platform | standard | yes | System Settings wording; no space before ブラウザ |
| Default web browser | デフォルトのWebブラウザ | platform | standard | yes | |
| Applications | アプリケーション | platform | standard | yes | the folder: 「アプリケーション」フォルダ |
| Move to Applications | 「アプリケーション」フォルダに移動 | ui | standard | yes | |
| Login Items | ログイン項目 | platform | standard | yes | |
| Battery Saver | 省エネモード | browser | verified | yes | Chrome's name; https://support.google.com/chrome/answer/12929150?hl=ja |
| Memory Saver | メモリセーバー | browser | verified | yes | https://support.google.com/chrome/answer/12929150?hl=ja |
| Address | アドレス | browser | standard | no | web address |
| URL | URL | browser | standard | yes | |
| Link | リンク | browser | standard | no | |
| Links | リンク | browser | standard | no | |
| Copy Link | リンクをコピー | menu | standard | yes | |
| Open Link in New Tab | リンクを新規タブで開く | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/sfri11576/mac |
| Open Link in New Window | リンクを新規ウインドウで開く | menu | standard | yes | |
| Download Linked File | リンク先のファイルをダウンロード | menu | standard | yes | |
| Copy Image | イメージをコピー | menu | standard | yes | Safari says イメージ, not 画像 |
| Save Image As… | イメージを別名で保存… | menu | unverified | yes | Safari's exact item not confirmed |
| Look Up | 調べる | menu | standard | no | 「%@」を調べる |
| Search with Google | Googleで検索 | menu | standard | yes | |
| Back | 戻る | browser | verified | no | 「戻る」ボタン |
| Forward | 進む | browser | verified | no | 「進む」ボタン |
| Home | ホーム | browser | standard | no | |
| Search | 検索 | ui | verified | no | |
| Search engine | 検索エンジン | browser | standard | yes | |
| Find on Page | ページ内を検索 | browser | standard | yes | |
| Page | ページ | browser | standard | no | |
| Pages | ページ | browser | standard | no | |
| Web page | ウェブページ | browser | verified | yes | Apple: ウェブページ |
| Media | メディア | browser | standard | no | |
| Video | ビデオ | ui | standard | no | Apple uses ビデオ, not 動画 |
| Mute | 消音 | browser | unverified | no | Apple prefers 消音; ミュート also seen |
| Unmute | 消音を解除 | browser | unverified | no | |
| Play | 再生 | ui | standard | no | |
| Pause | 一時停止 | ui | standard | no | |
| Cast | キャスト | browser | verified | no | menu item キャスト…; https://support.google.com/chrome/answer/3228332?hl=ja |
| Screenshot | スクリーンショット | platform | standard | yes | |
| Capture | キャプチャ | ui | standard | no | page capture |
| Print | プリント | ui | verified | no | Apple says プリント |
| Share | 共有 | platform | standard | no | |
| Open | 開く | ui | verified | no | |
| Close | 閉じる | ui | verified | no | |
| Save | 保存 | ui | verified | no | |
| Cancel | キャンセル | ui | standard | no | |
| Done | 完了 | ui | standard | no | |
| OK | OK | ui | standard | no | |
| Delete | 削除 | ui | verified | no | |
| Remove | 削除 | ui | standard | no | Apple uses 削除 for both |
| Rename | 名前を変更 | ui | standard | no | |
| Rename… | 名前を変更… | ui | standard | no | |
| Add | 追加 | ui | standard | no | |
| Edit… | 編集… | ui | standard | no | |
| Import | 読み込む | ui | standard | no | Apple: 読み込む; noun 読み込み |
| Export | 書き出す | ui | standard | no | Apple: 書き出す; noun 書き出し |
| Install | インストール | ui | standard | no | |
| Uninstall | アンインストール | ui | standard | no | |
| Update | アップデート | ui | standard | no | |
| Restore | 復元 | ui | standard | no | |
| Reset | リセット | ui | standard | no | |
| Clear | 消去 | ui | standard | no | |
| Turn On | オンにする | ui | standard | no | |
| Turn Off | オフにする | ui | standard | no | |
| On | オン | ui | standard | no | |
| Off | オフ | ui | standard | no | |
| Show | 表示 | ui | standard | no | |
| Hide | 非表示 | ui | verified | no | https://support.apple.com/ja-jp/102650 |
| Move | 移動 | ui | standard | no | |
| Choose… | 選択… | ui | standard | no | |
| Continue | 続ける | ui | standard | no | |
| Try Again | 再試行 | ui | standard | no | |
| Not Now | 今はしない | ui | standard | no | |
| Learn More | 詳しい情報 | ui | standard | no | |
| Default | デフォルト | ui | standard | no | |
| None | なし | ui | standard | no | |
| Always | 常に | ui | standard | no | |
| Never | しない | ui | standard | no | as an option; 一度も in prose |
| Name | 名前 | ui | standard | no | |
| Folder | フォルダ | platform | verified | no | 「新規フォルダ」; no long vowel |
| New Folder | 新規フォルダ | menu | verified | yes | https://support.apple.com/ja-jp/guide/safari/cpsh003/mac |
| Archive | アーカイブ | ui | standard | no | verb: アーカイブする |
| Archived | アーカイブ済み | ui | standard | no | |
| Theme | テーマ | ui | standard | no | |
| Color | カラー | ui | standard | no | Apple: カラー |
| Icon | アイコン | ui | standard | no | |
| Light | ライト | platform | standard | no | appearance |
| Dark | ダーク | platform | standard | no | appearance |
| Automatic | 自動 | platform | standard | no | |
| System | システム | ui | standard | no | |
| Shortcut | ショートカット | ui | standard | no | |
| Shortcuts | ショートカット | ui | standard | no | |
| Command | コマンド | ui | standard | no | also the Command key |
| Assistant | アシスタント | ui | standard | no | |
| Agent | エージェント | ui | standard | no | |
| Chat | チャット | ui | standard | no | |
| Chats | チャット | ui | standard | no | |
| Report a Problem… | 問題を報告… | ui | standard | yes | |
| Crash reports | クラッシュレポート | ui | standard | yes | |
| Developer | デベロッパ | ui | standard | no | Apple's spelling |
| Element | 要素 | ui | standard | no | |
| Proxy | プロキシ | browser | standard | yes | |
| Arx | Arx | arx | decided | yes | brand, never translated or transliterated |
| Little Arx | Little Arx | arx | decided | yes | coined name, keep English |
| Peek | Peek | arx | decided | yes | coined name, keep English |
| Air Traffic Control | Air Traffic Control | arx | decided | yes | coined name, keep English |
| Runway | Runway | arx | decided | yes | coined name, keep English |
| Space | スペース | arx | decided | yes | distinct from Apple's 操作スペース |
| Spaces | スペース | arx | decided | yes | no plural form |
| Space root | スペースのルート | arx | decided | no | rarely shown |
| Pinned tab | 固定されたタブ / 固定タブ | arx | verified | yes | Safari's term; https://support.apple.com/ja-jp/guide/safari/ibrw0495694f/mac |
| Favorite tab | お気に入りタブ | arx | decided | yes | Safari's お気に入り + タブ |
| Regular tab | 通常のタブ | arx | decided | yes | |
| Bookmark Tab | タブをブックマーク | arx | decided | yes | menu item |
| Tab Archive | タブアーカイブ | arx | decided | yes | same タブ as the Tab row |
| Clean Copy | クリーンコピー | arx | decided | yes | copying a link without tracking parameters |
| Copy Clean Link | クリーンリンクをコピー | arx | decided | yes | |
| Clean Link | クリーンリンク | arx | decided | yes | |
| Original Link | 元のリンク | arx | decided | yes | |
| Proxy Link | プロキシリンク | arx | decided | yes | |
| Copy Proxy Link | プロキシリンクをコピー | arx | decided | yes | |
| PiP | PiP | arx | decided | yes | keep PiP |
| Page PiP | ページPiP | arx | decided | yes | ページ + PiP, no space |
| Command Bar | コマンドバー | arx | decided | yes | |
| Media | メディア | arx | decided | no | SideMenu tab |
| SideMenu | サイドメニュー | arx | decided | no | not in UI text |
| Site menu | サイトメニュー | arx | decided | yes | |
| urlbar | アドレス | arx | decided | no | not in UI text; say アドレス where shown |
| Empty page | 空のページ | arx | decided | yes | |
| Routing rule | 振り分けルール | arx | decided | yes | rule deciding where a link opens |
| Search shortcut | 検索ショートカット | arx | decided | yes | |
| bang | bang | arx | decided | yes | keep English (!bang) |
| Badge | バッジ | arx | decided | yes | Apple's word for app-icon badges |
| Organization | 整理 / 構成 | arx | decided | no | arrangement of tabs and spaces, not a company (company is 組織) |
| Browser data | ブラウザデータ | arx | decided | yes | |
| Link Status | リンクの状態 | arx | decided | yes | Settings section |
| Live Calendar | ライブカレンダー | arx | decided | yes | |
| Setup Guide | セットアップガイド | arx | decided | yes | |
| Chrome Web Store | Chrome ウェブストア | arx | standard | yes | Google's Japanese name, with its space |
| WebKit | WebKit | arx | decided | yes | never translated |
| Chromium | Chromium | arx | decided | yes | never translated |
| MCP | MCP | arx | decided | yes | never translated |
| Arx Manual | Arxユーザガイド | arx | decided | yes | Apple's ユーザガイド |
| Arx Assistant | Arxアシスタント | arx | decided | yes | |
