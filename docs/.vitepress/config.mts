import { defineConfig, type DefaultTheme } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

/**
 * Structure: Diátaxis-style chapters ordered by *what the reader is trying to do*
 * (run it → understand it → operate it → look it up → change it → archive).
 *
 * i18n: symmetric parallel trees — `/en/` and `/cn/` hold identical file names,
 *       language is selected by directory (RocketMQ shape). Neither language owns
 *       the site root; `docs/index.md` is a bilingual chooser for `/`.
 *       The sidebar is generated from one STRUCTURE table + one LABELS map so the
 *       two locales cannot drift apart; adding a page is a single row edit below.
 */

const REPO = 'https://github.com/guangyiliushan/mortarmq'

type Lang = 'en' | 'zh'

/** Chapter order = reading order. Every chapter must expose an `index` page. */
const STRUCTURE: { chapter: string; pages: string[] }[] = [
  { chapter: 'getting-started', pages: ['index', 'quickstart'] },
  { chapter: 'concepts', pages: ['index', 'basics', 'architecture', 'diagrams/', 'message-loss', 'duplicate-delivery', 'ordering', 'security', 'glossary'] },
  { chapter: 'guides', pages: ['index', 'deploy-cluster', 'production-checklist', 'runbook', 'troubleshooting', 'upgrade', 'best-practices', 'faq'] },
  { chapter: 'reference', pages: ['index', 'protocol', 'errors', 'configuration', 'cli', 'metrics', 'api/'] },
  { chapter: 'develop', pages: ['index', 'testing', 'benchmarks'] },
]

/** `<chapter>` keys name chapters; `<chapter>/<page>` keys name pages. */
const LABELS: Record<Lang, Record<string, string>> = {
  en: {
    'getting-started': 'Getting Started',
    'getting-started/index': 'Overview',
    'getting-started/quickstart': 'Quick start',
    concepts: 'Concepts',
    'concepts/index': 'Overview',
    'concepts/basics': 'Core concepts',
    'concepts/message-loss': 'Message loss',
    'concepts/duplicate-delivery': 'Duplicate delivery',
    'concepts/ordering': 'Ordering',
    'concepts/architecture': 'Architecture',
    'concepts/diagrams/': 'Diagram atlas',
    'concepts/security': 'Security',
    'concepts/glossary': 'Glossary',
    guides: 'Guides',
    'guides/index': 'Overview',
    'guides/deploy-cluster': 'Deploy a cluster',
    'guides/production-checklist': 'Production checklist',
    'guides/runbook': 'Runbook',
    'guides/troubleshooting': 'Troubleshooting',
    'guides/upgrade': 'Upgrade',
    'guides/best-practices': 'Best practices',
    'guides/faq': 'FAQ',
    reference: 'Reference',
    'reference/index': 'Overview',
    'reference/protocol': 'Protocol',
    'reference/errors': 'Error codes',
    'reference/configuration': 'Configuration',
    'reference/cli': 'CLI',
    'reference/metrics': 'Metrics',
    'reference/api/': 'API',
    develop: 'Develop',
    'develop/index': 'Overview',
    'develop/testing': 'Testing',
    'develop/benchmarks': 'Benchmarks',
  },
  zh: {
    'getting-started': '入门',
    'getting-started/index': '本章概览',
    'getting-started/quickstart': '快速开始',
    concepts: '核心概念',
    'concepts/index': '本章概览',
    'concepts/basics': '基础概念',
    'concepts/message-loss': '消息丢失',
    'concepts/duplicate-delivery': '消息重复',
    'concepts/ordering': '顺序性',
    'concepts/architecture': '架构',
    'concepts/diagrams/': '图集',
    'concepts/security': '安全边界',
    'concepts/glossary': '术语表',
    guides: '使用指南',
    'guides/index': '本章概览',
    'guides/deploy-cluster': '部署集群',
    'guides/production-checklist': '生产就绪清单',
    'guides/runbook': '故障处置手册',
    'guides/troubleshooting': '故障排查',
    'guides/upgrade': '升级与回滚',
    'guides/best-practices': '最佳实践',
    'guides/faq': '常见问题',
    reference: '参考手册',
    'reference/index': '本章概览',
    'reference/protocol': '线协议',
    'reference/errors': '错误码',
    'reference/configuration': '配置',
    'reference/cli': '命令行',
    'reference/metrics': '指标',
    'reference/api/': 'API',
    develop: '开发',
    'develop/index': '本章概览',
    'develop/testing': '测试',
    'develop/benchmarks': '基准测试',
  },
}

function sidebar(prefix: string, lang: Lang): DefaultTheme.SidebarItem[] {
  const label = LABELS[lang]
  return STRUCTURE.map(({ chapter, pages }) => ({
    text: label[chapter],
    collapsed: false,
    items: pages.map((page) => {
      const key = page === 'index' ? `${chapter}/index` : `${chapter}/${page}`
      const link =
        page === 'index'
          ? `${prefix}/${chapter}/`
          : `${prefix}/${chapter}/${page.replace(/\/$/, '')}/`
      return { text: label[key], link }
    }),
  }))
}

function localeTheme(prefix: string, lang: Lang): DefaultTheme.Config {
  const zh = lang === 'zh'
  return {
    sidebar: sidebar(prefix, lang),
    outline: 'deep',
    label: zh ? '简体中文' : 'English',
    selectText: zh ? '选择语言' : 'Languages',
    lastUpdatedText: zh ? '最后更新' : 'Last updated',
    docFooter: { prev: zh ? '上一篇' : 'Previous', next: zh ? '下一篇' : 'Next' },
    darkModeSwitchLabel: zh ? '主题' : 'Appearance',
    sidebarMenuLabel: zh ? '菜单' : 'Menu',
    returnToTopLabel: zh ? '回到顶部' : 'Back to top',
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: zh ? '搜索' : 'Search', buttonAriaLabel: zh ? '搜索' : 'Search' },
          modal: {
            noResultsText: zh ? '没有找到结果' : 'No results found',
            resetButtonTitle: zh ? '清除查询' : 'Clear query',
            footer: {
              selectText: zh ? '选择' : 'select',
              navigateText: zh ? '切换' : 'to navigate',
              closeText: zh ? '关闭' : 'close',
            },
          },
        },
      },
    },
  }
}

export default withMermaid(
  defineConfig({
    title: 'MortarMQ',
    description:
      'A message queue built natively in MoonBit: wire-protocol access, produce/consume, partitioned topics, at-least-once delivery with dead-letter handling, and durable crash recovery',
    // The site is served from a GitHub Pages project path, so it lives under
    // this sub-path. VitePress prepends `base` to root-absolute URLs in
    // markdown links, assets and `head` entries; relative links are unaffected.
    // Switch to `'/'` if the site ever moves to a custom-domain root.
    base: '/mortarmq/',
    // `demo/` is copied into the build output by docs-site.yml AFTER `vitepress build`,
    // so it cannot exist at link-check time. Everything else stays gated.
    ignoreDeadLinks: [/^\/demo\//],
    // Locale keys must be BARE names with an explicit `link`. VitePress resolves the
    // current locale by matching `/${key}/` against the path, so a path-style key like
    // `'/en/'` would be tested as `'//en//'`, never match, and fall back to the
    // root theme — which silently drops the sidebar.
    locales: {
      en: {
        label: 'English',
        lang: 'en-US',
        link: '/en/',
        themeConfig: localeTheme('/en', 'en'),
      },
      cn: {
        label: '简体中文',
        lang: 'zh-CN',
        link: '/cn/',
        themeConfig: localeTheme('/cn', 'zh'),
      },
    },
    themeConfig: {
      lastUpdated: true,
      socialLinks: [{ icon: 'github', link: REPO }],
    },
  })
)
