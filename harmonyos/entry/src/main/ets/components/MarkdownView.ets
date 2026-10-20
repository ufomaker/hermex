import { MarkdownBlock, parseMarkdownBlocks } from './MarkdownParser';

@Component
export struct MarkdownView {
  @Prop content: string = '';
  @State blocks: MarkdownBlock[] = [];

  aboutToAppear() {
    this.updateBlocks();
  }

  aboutToUpdate() {
    this.updateBlocks();
  }

  private updateBlocks() {
    this.blocks = parseMarkdownBlocks(this.content);
  }

  build() {
    Column() {
      ForEach(this.blocks, (block: MarkdownBlock) => {
        if (block.type === 'heading') {
          Text(block.content)
            .fontSize(block.level === 1 ? 18 : (block.level === 2 ? 16 : 14))
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
            .margin({ top: 8, bottom: 4 })
            .width('100%')
        } else if (block.type === 'code') {
          Column() {
            if (block.language) {
              Text(block.language)
                .fontSize(10)
                .fontColor('#9CA3AF')
                .margin({ bottom: 4 })
            }
            Text(block.content)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor('#1F2937')
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#F3F4F6')
          .borderRadius(6)
          .margin({ top: 4, bottom: 4 })
          .alignItems(HorizontalAlign.Start)
        } else if (block.type === 'table' && block.rows) {
          Column() {
            ForEach(block.rows, (row: string[]) => {
              Row() {
                ForEach(row, (cell: string) => {
                  Text(cell)
                    .fontSize(11)
                    .fontColor('#374151')
                    .padding(4)
                    .layoutWeight(1)
                    .border({ width: 0.5, color: '#E5E7EB' })
                })
              }
              .width('100%')
            })
          }
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        } else if (block.type === 'blockquote') {
          Row() {
            Column()
              .width(3)
              .height('100%')
              .backgroundColor('#3B82F6')
              .margin({ right: 6 })
            Text(block.content)
              .fontSize(13)
              .fontColor('#4B5563')
              .fontStyle(FontStyle.Italic)
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
          .margin({ top: 2, bottom: 2 })
        } else if (block.type === 'list') {
          Row() {
            Text('• ')
              .fontSize(13)
              .fontColor('#4B5563')
            Text(block.content)
              .fontSize(13)
              .fontColor('#1F2937')
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 2, bottom: 2 })
        } else {
          Text(block.content)
            .fontSize(13)
            .fontColor('#1F2937')
            .lineHeight(19)
            .margin({ top: 2, bottom: 2 })
            .width('100%')
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
