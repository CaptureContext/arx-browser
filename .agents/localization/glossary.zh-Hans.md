# Glossary: Simplified Chinese (zh-Hans)

Translators of Arx into Simplified Chinese use these terms. A term here wins over any other choice.

## Language rules

- Address: informal 你, never 您, as Apple's Simplified Chinese macOS and Safari do ("如果忘记使用无痕浏览窗口，则可以清除你的浏览历史记录。"). Verified: https://support.apple.com/zh-cn/guide/safari/ibrw1069/mac
- Capitalization: not applicable. Latin-script names keep their own casing (Arx, Peek, iCloud, Touch ID, Safari, Cookie).
- Spacing: Apple's Simplified Chinese puts one half-width space between Chinese and Latin words or digits ("Mac 上的 Safari 浏览器", "启用 Cookie", "按住 Control 键"). Write "退出 Arx", "关于 Arx", "iCloud 钥匙串", "JavaScript 控制台". No space between Chinese and full-width punctuation. Verified: https://support.apple.com/zh-cn/guide/safari/welcome/mac
- Punctuation: full-width ，。：；！？（） in Chinese text; enumeration comma 、. Quote UI names with “” (nested ‘’), never 「」 or "". Menu paths are written “显示”>“边栏” with > between quoted items; where the English source uses ›, write >.
- Ellipsis: a single "…" (U+2026) directly after the word in menu items and buttons (打印…, 设置…), as Apple's menus do. In running prose the Chinese ellipsis is ……; do not use "...".
- Apps: Apple writes "App" in Latin letters (“密码” App, “网站和 App”), not 应用 or 应用程序, except the Applications folder (“应用程序”文件夹).
- Copy is 拷贝 and Save is 存储 in Apple's menus (verified on https://support.apple.com/zh-cn/102650); Duplicate is 复制. Do not use 复制 for Copy or 保存 for Save.
- Apple localizes several product names: Finder is 访达, Dock is 程序坞, Mission Control is 调度中心, Split View is 分屏浏览, Profiles are 用户场景. Use them; they are not kept in English in this language.
- Private and Incognito: Safari's Private Browsing is 无痕浏览 (window 无痕浏览窗口); Chrome's Incognito is 无痕模式 (window 无痕式窗口). Arx says Incognito, so use the Chrome forms for Arx's incognito and the Safari forms only where the English says Private.
- Plural categories: other only. Chinese has no plural forms; Tab and Tabs are both 标签页. Counts use a measure word: "%lld 个标签页".
- macOS Spaces: Apple calls them 空间 (Mission Control is 调度中心, the bar is 空间栏). Verified: https://support.apple.com/zh-cn/guide/mac-help/mh14112/mac
- Arx space: 分区, because 空间 is Apple's word for macOS Spaces, 用户场景 is Apple's word for profiles, 工作区 reads as "workspace" (which Arx's vocabulary forbids), and 分区 says "a section of the sidebar" in two characters.

## Terms

| English | Translation | Kind | Status | Check | Note |
| --- | --- | --- | --- | --- | --- |
| File | 文件 | menu | verified | no | menu bar title; https://support.apple.com/zh-cn/guide/safari/ibrw1069/mac |
| Edit | 编辑 | menu | standard | no | menu bar title |
| View | 显示 | menu | verified | no | menu bar title; Apple says 显示, not 视图 |
| History | 历史记录 | menu | verified | no | Safari menu bar title |
| Window | 窗口 | menu | verified | no | menu bar title |
| Help | 帮助 | menu | standard | no | menu bar title |
| Services | 服务 | menu | standard | yes | app menu |
| About Arx | 关于 Arx | menu | standard | yes | macOS pattern 关于 <App> |
| Hide Arx | 隐藏 Arx | menu | standard | yes | macOS pattern 隐藏 <App> |
| Hide Others | 隐藏其他 | menu | standard | yes | app menu |
| Show All | 全部显示 | menu | standard | yes | app menu |
| Quit Arx | 退出 Arx | menu | verified | yes | 退出当前 App on https://support.apple.com/zh-cn/102650 |
| Undo | 撤销 | menu | verified | no | https://support.apple.com/zh-cn/102650 |
| Redo | 重做 | menu | verified | no | |
| Cut | 剪切 | menu | verified | no | |
| Copy | 拷贝 | menu | verified | no | not 复制 |
| Paste | 粘贴 | menu | verified | no | |
| Paste and Match Style | 粘贴并匹配样式 | menu | verified | yes | https://support.apple.com/zh-cn/102650 |
| Select All | 全选 | menu | standard | yes | Edit menu |
| Find | 查找 | menu | verified | no | |
| Use Selection for Find | 使用所选内容查找 | menu | standard | yes | Edit > 查找 |
| Jump to Selection | 跳到所选内容 | menu | standard | yes | Edit > 查找 |
| Spelling and Grammar | 拼写和语法 | menu | verified | yes | https://support.apple.com/zh-cn/102650 |
| Show Spelling and Grammar | 显示拼写和语法 | menu | standard | yes | |
| Check Document Now | 立即检查文稿 | menu | standard | yes | Apple says 文稿 for document |
| Check Grammar With Spelling | 检查拼写时同时检查语法 | menu | unverified | yes | exact Apple wording not confirmed |
| Correct Spelling Automatically | 自动纠正拼写 | menu | standard | yes | |
| Substitutions | 替换 | menu | standard | yes | Edit submenu |
| Smart Links | 智能链接 | menu | standard | yes | |
| Transformations | 转换 | menu | standard | yes | Edit submenu |
| Make Upper Case | 转换成大写 | menu | standard | yes | |
| Make Lower Case | 转换成小写 | menu | standard | yes | |
| Capitalize | 首字母大写 | menu | standard | yes | |
| Minimize | 最小化 | menu | verified | no | https://support.apple.com/zh-cn/102650 |
| Zoom | 缩放 | menu | standard | no | Window menu (window zoom) |
| Bring All to Front | 前置全部窗口 | menu | standard | yes | Window menu |
| Enter Full Screen | 进入全屏幕 | menu | standard | yes | Apple says 全屏幕 |
| Exit Full Screen | 退出全屏幕 | menu | standard | yes | |
| Full Screen | 全屏幕 | platform | verified | yes | https://support.apple.com/zh-cn/guide/mac-help/mh14112/mac |
| Zoom In | 放大 | menu | standard | no | Safari View menu |
| Zoom Out | 缩小 | menu | standard | no | Safari View menu |
| Actual Size | 实际大小 | menu | standard | yes | Safari View menu |
| Reload Page | 重新加载页面 | menu | standard | yes | Safari View menu; verb 重新加载 verified |
| Reload | 重新加载 | browser | verified | no | “重新加载降低隐私保护”; https://support.apple.com/zh-cn/guide/safari/ibrw1069/mac |
| Stop Loading | 停止加载 | menu | unverified | yes | Safari's exact wording not confirmed |
| Print… | 打印… | menu | verified | yes | https://support.apple.com/zh-cn/102650 |
| Page Setup… | 页面设置… | menu | standard | yes | File menu |
| Save Page As… | 页面存储为… | menu | standard | yes | Apple's 存储为… pattern |
| Open File… | 打开文件… | menu | standard | yes | File menu |
| Close Window | 关闭窗口 | menu | standard | yes | File menu |
| Close Tab | 关闭标签页 | menu | verified | yes | “在 Mac 上的 Safari 浏览器中关闭标签页” |
| New Window | 新建窗口 | menu | standard | yes | Safari File menu |
| New Tab | 新建标签页 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/sfri11576/mac |
| New Private Window | 新建无痕浏览窗口 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/ibrw1069/mac |
| New Incognito Window | 新建无痕式窗口 | browser | decided | yes | Apple's 新建… pattern with Chrome's 无痕式窗口 (Chrome: 打开新的无痕式窗口) |
| Incognito | 无痕模式 / 无痕式窗口 | browser | verified | yes | https://support.google.com/chrome/answer/95464?hl=zh-hans |
| Private window | 无痕浏览窗口 | platform | verified | yes | Safari; https://support.apple.com/zh-cn/guide/safari/ibrw1069/mac |
| Private Browsing | 无痕浏览 | platform | verified | yes | Safari |
| Reopen Closed Window | 重新打开关闭的窗口 | browser | unverified | yes | Chrome's Chinese wording not confirmed |
| Recently Closed | 最近关闭 | menu | verified | yes | “历史记录”>“最近关闭”; https://support.apple.com/zh-cn/guide/safari/sfri11576/mac |
| Show All History | 显示所有历史记录 | menu | standard | yes | Safari History menu |
| Clear History… | 清除历史记录… | menu | standard | yes | Safari History menu |
| Show Next Tab | 显示下一个标签页 | menu | standard | yes | Safari Window menu |
| Show Previous Tab | 显示上一个标签页 | menu | standard | yes | Safari Window menu |
| Duplicate Tab | 复制标签页 | menu | standard | yes | Duplicate is 复制 |
| Pin Tab | 固定标签页 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/ibrw0495694f/mac |
| Unpin Tab | 取消固定标签页 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/ibrw0495694f/mac |
| Mute Tab | 将标签页静音 | browser | unverified | yes | Chrome's tab menu wording not confirmed |
| Unmute Tab | 取消标签页静音 | browser | unverified | yes | |
| Move Tab to New Window | 将标签页移到新窗口 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/sfri11576/mac |
| Merge All Windows | 合并所有窗口 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/ibrwbb6e21e4/mac |
| Developer Tools | 开发者工具 | browser | standard | yes | Chrome |
| Inspect Element | 检查元素 | menu | standard | yes | |
| JavaScript Console | JavaScript 控制台 | browser | standard | yes | space before Chinese |
| View Page Source | 查看网页源代码 | browser | standard | yes | Chrome |
| Keyboard Shortcuts | 键盘快捷键 | platform | verified | yes | https://support.apple.com/zh-cn/guide/safari/welcome/mac |
| Check for Updates… | 检查更新… | menu | standard | yes | |
| Share… | 共享… | menu | standard | yes | Apple says 共享 |
| Tab | 标签页 | platform | verified | no | Safari; the Tab key is Tab 键 |
| Tabs | 标签页 | platform | verified | no | no plural form |
| Window | 窗口 | platform | verified | no | |
| Tab group | 标签页组 | platform | standard | yes | Safari guide title: “给标签页分组” |
| Favorites | 个人收藏 | platform | verified | yes | https://support.apple.com/zh-cn/guide/safari/welcome/mac |
| Favorite | 个人收藏 | platform | verified | yes | |
| Bookmarks | 书签 | platform | verified | yes | |
| Bookmark | 书签 | platform | verified | yes | verb: 添加书签 |
| Add Bookmark | 添加书签 | menu | standard | yes | |
| History | 历史记录 | platform | verified | no | browsing history: 浏览历史记录 |
| Downloads | 下载 | platform | verified | no | |
| Download | 下载 / 下载项 | platform | verified | no | noun 下载项 |
| Picture in Picture | 画中画 | platform | standard | yes | |
| Split View | 分屏浏览 | platform | verified | yes | localized, not English; https://support.apple.com/zh-cn/guide/mac-help/mh14112/mac |
| Full Disk Access | 完全磁盘访问权限 | platform | verified | yes | https://support.apple.com/zh-cn/guide/mac-help/mchlccb25729/mac |
| Privacy & Security | 隐私与安全 | platform | verified | yes | current macOS drops 性; https://support.apple.com/zh-cn/guide/mac-help/mchlccb25729/mac |
| System Settings | 系统设置 | platform | verified | yes | |
| Settings | 设置 | platform | verified | no | “Safari 浏览器”>“设置” |
| Settings… | 设置… | menu | standard | yes | app menu item |
| General | 通用 | platform | verified | no | Settings tab |
| Appearance | 外观 | platform | standard | no | |
| Advanced | 高级 | platform | verified | no | Settings tab |
| Extensions | 扩展 | platform | verified | yes | https://support.apple.com/zh-cn/guide/safari/welcome/mac |
| Extension | 扩展 | platform | verified | yes | |
| Passwords | 密码 | platform | verified | no | Safari tab and app; https://support.apple.com/zh-cn/guide/passwords/welcome/mac |
| Apple Passwords | “密码” App / 密码 | platform | verified | yes | app name is 密码; in sentences “密码” App |
| Keychain | 钥匙串 | platform | verified | yes | iCloud 钥匙串 |
| Keychain Access | 钥匙串访问 | platform | verified | yes | https://support.apple.com/zh-cn/guide/keychain-access/welcome/mac |
| Profile | 用户场景 | platform | verified | yes | Safari profiles; “创建用户场景” on https://support.apple.com/zh-cn/guide/safari/welcome/mac |
| Profiles | 用户场景 | platform | verified | yes | |
| Sidebar | 边栏 | platform | verified | yes | |
| Show Sidebar | 显示边栏 | menu | standard | yes | Safari View menu |
| Hide Sidebar | 隐藏边栏 | menu | standard | yes | Safari View menu |
| Toggle Sidebar | 显示或隐藏边栏 | browser | decided | yes | Apple's 显示或隐藏…边栏 pattern (https://support.apple.com/zh-cn/guide/safari/cpsh003/mac) |
| Reader | 阅读器 | platform | verified | yes | “打开阅读器”; https://support.apple.com/zh-cn/guide/safari/cpsh003/mac |
| Reading Mode | 阅读模式 | browser | verified | yes | https://support.google.com/chrome/answer/14218344?hl=zh-hans |
| Reading List | 阅读列表 | platform | verified | yes | |
| Website | 网站 | platform | verified | no | |
| Websites | 网站 | platform | verified | no | Safari Settings tab |
| Site | 网站 | browser | verified | no | Chrome |
| Site Settings | 网站设置 | browser | verified | yes | https://support.google.com/chrome/answer/114662?hl=zh-hans |
| Permissions | 权限 | browser | verified | no | |
| Allow | 允许 | ui | standard | no | |
| Don't Allow | 不允许 | ui | standard | yes | Apple permission button |
| Always Allow | 始终允许 | ui | standard | yes | |
| Allow Once | 允许一次 | ui | unverified | yes | exact Apple and Chrome wording not confirmed |
| Ask | 询问 | ui | standard | no | |
| Block | 阻止 | ui | standard | no | |
| Camera | 摄像头 | platform | verified | yes | https://support.google.com/chrome/answer/114662?hl=zh-hans |
| Microphone | 麦克风 | platform | verified | yes | |
| Location | 位置信息 | platform | verified | no | site permission; Apple's service is 定位服务 |
| Notifications | 通知 | platform | verified | no | |
| Cookies | Cookie | browser | verified | yes | kept in English; “启用 Cookie” |
| Cache | 缓存 | browser | standard | yes | |
| Clear Cache | 清除缓存 | browser | standard | yes | |
| Clear History | 清除历史记录 | browser | verified | yes | “清除你的浏览历史记录” |
| Browsing data | 浏览数据 | browser | standard | yes | Chrome: 删除浏览数据 |
| Autofill | 自动填充 | platform | standard | yes | |
| Passkey | 通行密钥 | platform | verified | yes | https://support.apple.com/zh-cn/guide/passwords/welcome/mac |
| Passkeys | 通行密钥 | platform | verified | yes | |
| Sign in | 登录 | ui | standard | no | |
| Sign-in | 登录 | ui | standard | no | |
| Sign Out | 退出登录 | ui | standard | yes | |
| Account | 账户 | ui | standard | no | |
| iCloud | iCloud | platform | verified | yes | never translated |
| Touch ID | Touch ID | platform | standard | yes | never translated |
| Mission Control | 调度中心 | platform | verified | yes | localized, not English; https://support.apple.com/zh-cn/102650 |
| Spaces (macOS) | 空间 | platform | verified | yes | never use for Arx spaces; https://support.apple.com/zh-cn/guide/mac-help/mh14112/mac |
| Desktop | 桌面 | platform | verified | no | |
| Dock | 程序坞 | platform | verified | yes | localized, not English; https://support.apple.com/zh-cn/102650 |
| Finder | 访达 | platform | verified | yes | Apple localizes Finder in zh-Hans; https://support.apple.com/zh-cn/102650 |
| Menu bar | 菜单栏 | platform | verified | yes | |
| Language & Region | 语言与地区 | platform | standard | yes | |
| Translate | 翻译 | platform | verified | no | “翻译网页” |
| Translation | 翻译 | platform | verified | no | |
| Default browser | 默认网页浏览器 | platform | verified | yes | “将 Safari 浏览器设置为默认网页浏览器” |
| Default web browser | 默认网页浏览器 | platform | verified | yes | |
| Applications | 应用程序 | platform | standard | yes | the folder: “应用程序”文件夹 |
| Move to Applications | 移到“应用程序”文件夹 | ui | standard | yes | |
| Login Items | 登录项 | platform | standard | yes | |
| Battery Saver | 节能模式 | browser | verified | yes | https://support.google.com/chrome/answer/12929150?hl=zh-hans |
| Memory Saver | 省内存模式 | browser | verified | yes | https://support.google.com/chrome/answer/12929150?hl=zh-hans |
| Address | 地址 | browser | standard | no | web address |
| URL | URL | browser | standard | yes | |
| Link | 链接 | browser | standard | no | |
| Links | 链接 | browser | standard | no | |
| Copy Link | 拷贝链接 | menu | standard | yes | Copy is 拷贝 |
| Open Link in New Tab | 在新标签页中打开链接 | menu | verified | yes | https://support.apple.com/zh-cn/guide/safari/sfri11576/mac |
| Open Link in New Window | 在新窗口中打开链接 | menu | standard | yes | |
| Download Linked File | 下载链接文件 | menu | standard | yes | |
| Copy Image | 拷贝图像 | menu | standard | yes | |
| Save Image As… | 图像存储为… | menu | unverified | yes | exact Safari item not confirmed |
| Look Up | 查询 | menu | standard | no | 查询“%@” |
| Search with Google | 使用 Google 搜索 | menu | standard | yes | |
| Back | 返回 | browser | verified | no | “返回”按钮; https://support.apple.com/zh-cn/guide/safari/sfri11576/mac |
| Forward | 向前 | browser | verified | no | “向前”按钮 |
| Home | 主页 | browser | verified | no | “更改主页” |
| Search | 搜索 | ui | verified | no | |
| Search engine | 搜索引擎 | browser | standard | yes | |
| Find on Page | 在页面上查找 | browser | standard | yes | |
| Page | 页面 | browser | standard | no | |
| Pages | 页面 | browser | standard | no | |
| Web page | 网页 | browser | verified | yes | |
| Media | 媒体 | browser | standard | no | |
| Video | 视频 | ui | standard | no | |
| Mute | 静音 | browser | standard | no | |
| Unmute | 取消静音 | browser | standard | no | |
| Play | 播放 | ui | standard | no | |
| Pause | 暂停 | ui | standard | no | |
| Cast | 投放 | browser | verified | no | menu item 投放…; https://support.google.com/chrome/answer/3228332?hl=zh-hans |
| Screenshot | 截屏 | platform | standard | yes | |
| Capture | 截取 | ui | standard | no | page capture |
| Print | 打印 | ui | verified | no | |
| Share | 共享 | platform | standard | no | |
| Open | 打开 | ui | verified | no | |
| Close | 关闭 | ui | verified | no | |
| Save | 存储 | ui | verified | no | Apple says 存储, not 保存 |
| Cancel | 取消 | ui | standard | no | |
| Done | 完成 | ui | standard | no | |
| OK | 好 | ui | standard | no | Apple's OK button is 好 |
| Delete | 删除 | ui | standard | no | |
| Remove | 移除 | ui | standard | no | |
| Rename | 重新命名 | ui | standard | no | |
| Rename… | 重新命名… | ui | standard | no | |
| Add | 添加 | ui | standard | no | |
| Edit… | 编辑… | ui | standard | no | |
| Import | 导入 | ui | standard | no | |
| Export | 导出 | ui | standard | no | |
| Install | 安装 | ui | standard | no | |
| Uninstall | 卸载 | ui | standard | no | |
| Update | 更新 | ui | standard | no | |
| Restore | 恢复 | ui | standard | no | |
| Reset | 重置 | ui | standard | no | |
| Clear | 清除 | ui | standard | no | |
| Turn On | 打开 | ui | standard | no | |
| Turn Off | 关闭 | ui | standard | no | |
| On | 开 | ui | standard | no | switch state |
| Off | 关 | ui | standard | no | switch state |
| Show | 显示 | ui | standard | no | |
| Hide | 隐藏 | ui | standard | no | |
| Move | 移动 | ui | standard | no | |
| Choose… | 选取… | ui | standard | no | Apple says 选取 |
| Continue | 继续 | ui | standard | no | |
| Try Again | 重试 | ui | standard | no | |
| Not Now | 以后 | ui | standard | no | |
| Learn More | 进一步了解 | ui | standard | no | |
| Default | 默认 | ui | standard | no | |
| None | 无 | ui | standard | no | |
| Always | 始终 | ui | standard | no | |
| Never | 永不 | ui | standard | no | |
| Name | 名称 | ui | standard | no | |
| Folder | 文件夹 | platform | standard | no | |
| New Folder | 新建文件夹 | menu | standard | yes | |
| Archive | 归档 | ui | standard | no | verb and noun |
| Archived | 已归档 | ui | standard | no | |
| Theme | 主题 | ui | standard | no | |
| Color | 颜色 | ui | standard | no | |
| Icon | 图标 | ui | standard | no | |
| Light | 浅色 | platform | standard | no | appearance |
| Dark | 深色 | platform | standard | no | appearance |
| Automatic | 自动 | platform | standard | no | |
| System | 系统 | ui | standard | no | |
| Shortcut | 快捷键 | ui | standard | no | keyboard shortcut |
| Shortcuts | 快捷键 | ui | standard | no | |
| Command | 命令 | ui | standard | no | the key is Command 键 |
| Assistant | 助理 | ui | standard | no | |
| Agent | 智能体 | ui | decided | no | AI agent; 代理 is Proxy |
| Chat | 聊天 | ui | standard | no | |
| Chats | 聊天 | ui | standard | no | |
| Report a Problem… | 报告问题… | ui | standard | yes | |
| Crash reports | 崩溃报告 | ui | standard | yes | |
| Developer | 开发者 | ui | standard | no | |
| Element | 元素 | ui | standard | no | |
| Proxy | 代理 | browser | standard | yes | |
| Arx | Arx | arx | decided | yes | brand, never translated or transliterated |
| Little Arx | Little Arx | arx | decided | yes | coined name, keep English |
| Peek | Peek | arx | decided | yes | coined name, keep English |
| Air Traffic Control | Air Traffic Control | arx | decided | yes | coined name, keep English |
| Runway | Runway | arx | decided | yes | coined name, keep English |
| Space | 分区 | arx | decided | yes | 空间 is macOS Spaces, 用户场景 is profiles |
| Spaces | 分区 | arx | decided | yes | no plural form |
| Space root | 分区顶层 | arx | decided | no | rarely shown |
| Pinned tab | 固定的标签页 | arx | verified | yes | Safari's term; https://support.apple.com/zh-cn/guide/safari/ibrw0495694f/mac |
| Favorite tab | 个人收藏标签页 | arx | decided | yes | Safari's 个人收藏 + 标签页 |
| Regular tab | 普通标签页 | arx | decided | yes | |
| Bookmark Tab | 将标签页添加为书签 | arx | decided | yes | menu item |
| Tab Archive | 标签页归档 | arx | decided | yes | same 标签页 as the Tab row |
| Clean Copy | 纯净拷贝 | arx | decided | yes | copying a link without tracking parameters; 拷贝 as in Copy |
| Copy Clean Link | 拷贝纯净链接 | arx | decided | yes | |
| Clean Link | 纯净链接 | arx | decided | yes | |
| Original Link | 原始链接 | arx | decided | yes | |
| Proxy Link | 代理链接 | arx | decided | yes | |
| Copy Proxy Link | 拷贝代理链接 | arx | decided | yes | |
| PiP | 画中画 | arx | decided | yes | Apple's term; zh-Hans does not keep PiP |
| Page PiP | 网页画中画 | arx | decided | yes | |
| Command Bar | 命令栏 | arx | decided | yes | |
| Media | 媒体 | arx | decided | no | SideMenu tab |
| SideMenu | 侧边菜单 | arx | decided | no | not in UI text |
| Site menu | 网站菜单 | arx | decided | yes | |
| urlbar | 地址 | arx | decided | no | not in UI text; say 地址 where shown |
| Empty page | 空白页 | arx | decided | yes | |
| Routing rule | 路由规则 | arx | decided | yes | rule deciding where a link opens |
| Search shortcut | 搜索快捷词 | arx | decided | yes | a keyword, so not 快捷键 |
| bang | bang | arx | decided | yes | keep English (!bang) |
| Badge | 标记 | arx | decided | yes | unread mark on a tab icon |
| Organization | 整理 / 布局 | arx | decided | no | arrangement of tabs and spaces, not a company (company is 组织) |
| Browser data | 浏览器数据 | arx | decided | yes | |
| Link Status | 链接状态 | arx | decided | yes | Settings section |
| Live Calendar | 实时日历 | arx | decided | yes | |
| Setup Guide | 设置向导 | arx | decided | yes | |
| Chrome Web Store | Chrome 应用商店 | arx | standard | yes | Google's Chinese name |
| WebKit | WebKit | arx | decided | yes | never translated |
| Chromium | Chromium | arx | decided | yes | never translated |
| MCP | MCP | arx | decided | yes | never translated |
| Arx Manual | Arx 使用手册 | arx | decided | yes | Apple's 使用手册 |
| Arx Assistant | Arx 助理 | arx | decided | yes | |
