export interface MarkdownBlock {
  type: 'heading' | 'code' | 'paragraph' | 'blockquote' | 'list' | 'table';
  content: string;
  level?: number;
  language?: string;
  rows?: string[][];
}

export function parseMarkdownBlocks(rawText: string): MarkdownBlock[] {
  const lines = rawText.split('\n');
  const blocks: MarkdownBlock[] = [];
  let inCodeBlock = false;
  let codeLang = '';
  let codeLines: string[] = [];
  let tableRows: string[][] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // 代码块处理
    if (line.trim().startsWith('```')) {
      if (inCodeBlock) {
        blocks.push({
          type: 'code',
          content: codeLines.join('\n'),
          language: codeLang
        });
        inCodeBlock = false;
        codeLines = [];
        codeLang = '';
      } else {
        inCodeBlock = true;
        codeLang = line.trim().substring(3).trim();
      }
      continue;
    }

    if (inCodeBlock) {
      codeLines.push(line);
      continue;
    }

    // 表格处理
    if (line.trim().startsWith('|') && line.trim().endsWith('|')) {
      const cells = line.split('|').map(c => c.trim()).filter((c, idx, arr) => idx > 0 && idx < arr.length - 1);
      // 忽略分割线行 |---|---|
      if (cells.some(c => /^:?-+:?$/.test(c))) {
        continue;
      }
      tableRows.push(cells);
      // 检查下一行是否仍是表格
      const nextLine = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
      if (!nextLine.startsWith('|')) {
        blocks.push({
          type: 'table',
          content: '',
          rows: tableRows
        });
        tableRows = [];
      }
      continue;
    }

    // 标题处理
    if (line.startsWith('#')) {
      let level = 0;
      while (level < line.length && line[level] === '#') {
        level++;
      }
      const title = line.substring(level).trim();
      blocks.push({
        type: 'heading',
        content: title,
        level: level
      });
      continue;
    }

    // 引用块处理
    if (line.startsWith('>')) {
      blocks.push({
        type: 'blockquote',
        content: line.substring(1).trim()
      });
      continue;
    }

    // 列表项处理
    if (line.trim().startsWith('- ') || line.trim().startsWith('* ')) {
      blocks.push({
        type: 'list',
        content: line.trim().substring(2).trim()
      });
      continue;
    }

    // 普通文本段落
    if (line.trim().length > 0) {
      blocks.push({
        type: 'paragraph',
        content: line
      });
    }
  }

  if (inCodeBlock && codeLines.length > 0) {
    blocks.push({
      type: 'code',
      content: codeLines.join('\n'),
      language: codeLang
    });
  }

  return blocks;
}
