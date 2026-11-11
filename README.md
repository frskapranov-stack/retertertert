# cursor-skin

npx-скин для агента Cursor. Команда ставит одно проектное правило [`.cursor/rules/cursor-skin.mdc`](https://cursor.com/docs/rules) с `alwaysApply: true`. Новый чат Agent в этом репозитории начинает работать в выбранном стиле. Предыдущий скин заменяется.

```bash
npx github:frskapranov-stack/retertertert add laconic
```

## Команды

```bash
npx github:frskapranov-stack/retertertert list
npx github:frskapranov-stack/retertertert add reviewer
npx github:frskapranov-stack/retertertert current
npx github:frskapranov-stack/retertertert show mentor
npx github:frskapranov-stack/retertertert remove
```

`--target <каталог>` выбирает проект. По умолчанию это текущий каталог. `--force` перезаписывает файл, если его правили вручную.

Закоммитьте `.cursor/rules/cursor-skin.mdc`, если скин нужен всей команде. Правило действует в Agent и не влияет на Tab.

## Скины

| id | Имя | Что меняет |
| --- | --- | --- |
| `laconic` | Лаконичный | Сначала ответ, без воды и лишних альтернатив |
| `mentor` | Наставник | Почему так, и какой следующий шаг |
| `reviewer` | Ревьюер | Сначала риск, потом стиль |
| `architect` | Архитектор | Границы модулей и один рекомендуемый вариант |
| `minimal` | Минималист | Только нужный дифф, без попутного рефакторинга |
| `pair` | Напарник | Гипотеза, проверка по коду, одна команда проверки |

Текущая просьба в чате важнее скина.

## Локально

Нужен Node.js 18.18+.

```bash
node bin/cursor-skin.js add laconic
npm test
```
