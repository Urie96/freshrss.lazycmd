# freshrss.lazycmd

基于 FreshRSS Google Reader API 的 RSS 阅读插件。

目录结构已按 `examples/demo.lazycmd/demo` 的方式重构：

- `freshrss/init.lua` 负责路由和列表数据加载
- `freshrss/config.lua` 负责配置归一化
- `freshrss/meta.lua` 负责 entry 元表和局部 keymap
- `freshrss/action.lua` 负责预览、打开链接、标记状态和刷新缓存
- `freshrss/greader.lua` 负责 FreshRSS GReader API 客户端

## 功能

- 浏览未读文章
- 浏览收藏文章
- 按订阅源查看最新文章
- 预览正文
- 打开原文或订阅源站点
- 标记已读
- 收藏/取消收藏

## 配置

在 `examples/init.lua` 或 `~/.config/lazycmd/init.lua` 中配置：

```lua
{
  dir = 'plugins/freshrss.lazycmd',
  config = function()
    require('freshrss').setup {
      url = os.getenv 'FRESHRSS_URL',
      login = os.getenv 'FRESHRSS_LOGIN',
      password = os.getenv 'FRESHRSS_PASSWORD',
      page_size = 50,
      cache_ttl = 60,
      keymap = {
        open = 'o',
      },
    }
  end,
},
```

`url` 可以传 FreshRSS 站点根地址，也可以直接传 `.../api/greader.php` 或 `.../api/fever.php`，插件会自动归一化到 Google Reader API 入口。

## 键位

- `Enter`: 在文章上打开原文；在分类和订阅源上进入下一级
- `o`: 打开文章原文，或在订阅源列表中打开站点
- `r`: 标记当前文章已读
- `s`: 收藏或取消收藏当前文章
- `y`: 复制当前文章链接
- `R`: 清空缓存并刷新
