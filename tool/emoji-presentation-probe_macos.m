// emoji-presentation-probe_macos.m — 이모지 모양 (컬러 / 흑백) 을 CoreText 가 어떻게 고르는지 재는 진단 도구
// ([#771](https://github.com/ensky0/tildaz/issues/771)).
//
// ## 왜 필요한가
//
// macOS 앱은 글꼴을 두 갈래로 고른다 (`src/font/macos/font.zig`).
//
//   cluster   — `❤` + VS16 처럼 여러 글자를 한 칸에 그리는 것. Menlo 를 지정한 `CTLine` 을 만들어
//               CoreText 가 고른 글꼴을 쓴다 (`resolveGraphemeUncached`). 한 줄의 cluster 를
//               `CTLine` 하나로 묶어 shape 하는 경로도 있다 (`resolveGraphemeRunInner`).
//   단일 글자 — 우리 chain 을 앞에서부터 돌며 글리프가 있는 첫 글꼴을 쓴다 (`resolveGlyph`).
//
// #771 의 macOS 방향은 "cluster 의 글꼴 고르기는 CoreText 에 맡긴다" 는 전제 위에 선다. 그 전제
// (CoreText 가 VS16 은 컬러, VS15 는 흑백으로 고른다) 는 OS 동작이라 macOS · Apple Color Emoji 판이
// 바뀌면 다시 재야 한다. 단일 글자 쪽에서 고칠 글자 목록도 판마다 달라진다. 이 도구는 **앱 코드 밖에서**
// 앱과 같은 방식으로 CoreText 를 불러 그 둘을 잰다.
//
// ## 무엇을 재는가
//
//   cases       render-test 의 (M) 절과 같은 글자 (src/render_test.zig 의 sectionM) 를 세 경로로
//               돌려 run 마다 고른 글꼴을 찍는다. 화면 판정의 근거를 볼 때 쓴다.
//   vs <파일>    emoji-variation-sequences.txt 의 VS16 · VS15 시퀀스 전부를 cluster 경로로 판정한다.
//               같은 시퀀스를 40 개씩 이어 붙인 `CTLine` (묶음 경로) 으로도 shape 해서, 하나씩
//               처리할 때와 글꼴이 갈리는 cluster 를 센다. VS15 인데 컬러로 간 글자는 설치된 흑백
//               글꼴 전부에서 그 글자를 찾아, 흑백 글리프가 정말 없는지 함께 찍는다.
//   ep <파일>    emoji-data.txt 의 Emoji_Presentation=Yes 글자 전부를 단일 글자 경로로 판정한다.
//               chain 에 없으면 앱처럼 `CTFontCreateForString` 결과를 본다.
//
// 컬러인지는 **글꼴 단위로** 본다 — 글꼴에 컬러 표 (`sbix` · `COLR` · `CBDT`) 가 있는가. 글리프
// 하나하나의 색은 보지 않는다.
//
// chain 은 `src/config.zig` 의 macOS 기본값 (Menlo → Apple SD Gothic Neo → Apple Color Emoji →
// Apple Symbols) 을 PostScript 이름으로 적었다. 기본값이 바뀌면 아래 `kChain` 도 고친다.
//
// ## 빌드 · 실행
//
//   clang -fobjc-arc -framework Foundation -framework CoreText -framework CoreGraphics \
//         -o /tmp/emoji-presentation-probe tool/emoji-presentation-probe_macos.m
//   G=zig-pkg/$(sed -n '/\.ghostty = /,/hash/s/.*\.hash = "\(.*\)".*/\1/p' build.zig.zon)
//   U=zig-pkg/$(sed -n '/\.uucode = /,/hash/s/.*\.hash = "\(.*\)".*/\1/p' $G/build.zig.zon)/ucd/emoji
//   /tmp/emoji-presentation-probe cases
//   /tmp/emoji-presentation-probe vs "$U/emoji-variation-sequences.txt"
//   /tmp/emoji-presentation-probe ep "$U/emoji-data.txt"
//
// `U` 는 ghostty 가 셀 폭을 정할 때 쓰는 uucode 판이다. 판이 같아야 두 칸 글자와 이모지 모양이
// 맞는다. **우리 `build.zig.zon` 이 가리키는 ghostty 부터 따라간다** — `zig-pkg` 에는 옛 pin 의
// ghostty 와 그쪽 uucode 가 지워지지 않고 남아 있어서, `zig-pkg/ghostty-*` 로 고르면 둘이 잡힌다.
//
// ## 실측 (2026-10-16 · MacBook Pro M5 Pro · macOS 27.0.1 · Unicode 18.0 표)
//
//   vs  VS16 371 개 모두 컬러 (Apple Color Emoji). VS15 371 개 중 흑백 175 · 컬러 196 — 컬러 196 개
//       가운데 193 개는 흑백 글리프가 설치된 어느 글꼴에도 없고, 3 개 (U+27BF · U+1F315 · U+1F610)
//       는 사용자가 설치한 DejaVu (`~/Library/Fonts`) 와 macOS 내려받기 글꼴 Toppan 에만 있다.
//       묶음 경로와 갈린 cluster 0.
//   ep  1,228 개 중 Apple Color Emoji 1,200 · Menlo (흑백) 19 · LastResort 9.
//
// 자세한 결과와 목록은 #771 에 있다.

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

static NSArray<NSString *> *kChain;

static NSString *Str(const UTF32Char *cps, NSUInteger n) {
    return [[NSString alloc] initWithBytes:cps length:n * 4 encoding:NSUTF32LittleEndianStringEncoding];
}

// 코드 포인트를 `2764+FE0F` 꼴로. cluster 를 사람이 확인하는 데 쓴다.
static NSString *Hex(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *p = d.bytes;
    NSMutableArray *a = [NSMutableArray array];
    for (NSUInteger i = 0; i < d.length / 4; i++) [a addObject:[NSString stringWithFormat:@"%X", p[i]]];
    return [a componentsJoinedByString:@"+"];
}

static BOOL IsColorFont(CTFontRef f) {
    CFArrayRef tags = CTFontCopyAvailableTables(f, kCTFontTableOptionNoOptions);
    BOOL color = NO;
    for (CFIndex i = 0; tags && i < CFArrayGetCount(tags); i++) {
        CTFontTableTag t = (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex(tags, i);
        if (t == 'sbix' || t == 'COLR' || t == 'CBDT') color = YES;
    }
    if (tags) CFRelease(tags);
    return color;
}

static NSString *PSName(CTFontRef f) { return CFBridgingRelease(CTFontCopyPostScriptName(f)); }

static CTLineRef MakeLine(CTFontRef primary, NSString *s) {
    // 앱과 같다 — 속성은 primary 글꼴 하나, fallback 은 CoreText 가 고른다.
    NSDictionary *attrs = @{(id)kCTFontAttributeName : (__bridge id)primary};
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attrs];
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
}

// 한 줄을 shape 해 UTF-16 위치마다 그 자리의 첫 글리프를 담은 run 의 글꼴을 돌려준다.
// 앱의 묶음 경로가 `CTRunGetStringIndices` 로 cluster 를 찾는 것과 같은 방식이다.
static NSArray *FontsByIndex(CTFontRef primary, NSString *s) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) [out addObject:[NSNull null]];
    CTLineRef line = MakeLine(primary, s);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CTFontRef f = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFIndex n = CTRunGetGlyphCount(run);
        CGGlyph *g = calloc((size_t)n, sizeof(CGGlyph));
        CFIndex *idx = calloc((size_t)n, sizeof(CFIndex));
        CTRunGetGlyphs(run, CFRangeMake(0, n), g);
        CTRunGetStringIndices(run, CFRangeMake(0, n), idx);
        for (CFIndex i = 0; i < n; i++) {
            if (g[i] == 0 || idx[i] < 0 || (NSUInteger)idx[i] >= s.length) continue;
            if (out[(NSUInteger)idx[i]] == [NSNull null]) out[(NSUInteger)idx[i]] = (__bridge id)f;
        }
        free(g);
        free(idx);
    }
    CFRelease(line);
    return out;
}

// cluster 하나를 앱의 개별 경로대로 shape 해 첫 글리프의 글꼴을 돌려준다 (없으면 nil).
// **ARC 객체로 돌려준다.** `CTFontRef` 를 `__bridge` 로 돌려주면 이 함수의 배열이 풀리면서 글꼴이
// 해제돼 호출한 쪽이 해제된 글꼴을 읽는다 (처음 판이 그렇게 죽었다). 쓸 때 `__bridge CTFontRef` 로 바꾼다.
static id ClusterFont(CTFontRef primary, NSString *cluster) {
    NSArray *f = FontsByIndex(primary, cluster);
    for (id x in f)
        if (x != [NSNull null]) return x;
    return nil;
}

static void DumpLine(CTFontRef primary, NSString *label, NSString *s) {
    CTLineRef line = MakeLine(primary, s);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    printf("%s\n", label.UTF8String);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CTFontRef f = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFRange rr = CTRunGetStringRange(run);
        NSString *sub = [s substringWithRange:NSMakeRange((NSUInteger)rr.location, (NSUInteger)rr.length)];
        printf("    run%ld  %-24s %-5s glyphs=%ld  %s\n", (long)r, PSName(f).UTF8String,
               IsColorFont(f) ? "COLOR" : "mono", (long)CTRunGetGlyphCount(run), Hex(sub).UTF8String);
    }
    CFRelease(line);
}

// 앱의 단일 글자 경로 (`resolveGlyph`). 고른 글꼴 이름과 컬러 여부를 돌려준다.
static NSString *SingleFont(NSArray *chain, CTFontRef primary, UTF32Char c, BOOL *color) {
    unichar u[2];
    CFIndex len;
    if (c <= 0xFFFF) {
        u[0] = (unichar)c;
        len = 1;
    } else {
        UTF32Char v = c - 0x10000;
        u[0] = (unichar)(0xD800 + (v >> 10));
        u[1] = (unichar)(0xDC00 + (v & 0x3FF));
        len = 2;
    }
    for (NSUInteger i = 0; i < chain.count; i++) {
        CTFontRef f = (__bridge CTFontRef)chain[i];
        CGGlyph g[2] = {0, 0};
        if (CTFontGetGlyphsForCharacters(f, u, g, len) && g[0] != 0) {
            *color = IsColorFont(f);
            return kChain[i];
        }
    }
    CFStringRef s = CFStringCreateWithCharacters(NULL, u, len);
    CTFontRef fb = CTFontCreateForString(primary, s, CFRangeMake(0, len));
    CFRelease(s);
    NSString *name = @"(none)";
    *color = NO;
    CGGlyph g[2] = {0, 0};
    if (fb && CTFontGetGlyphsForCharacters(fb, u, g, len) && g[0] != 0) {
        name = [@"fallback:" stringByAppendingString:PSName(fb)];
        *color = IsColorFont(fb);
    }
    if (fb) CFRelease(fb);
    return name;
}

// `XXXX` 또는 `XXXX..YYYY` 를 펼친다.
static void AddRange(NSString *field, NSMutableArray *out) {
    NSString *t = [field stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray *ab = [t componentsSeparatedByString:@".."];
    unsigned a = 0, b = 0;
    [[NSScanner scannerWithString:ab[0]] scanHexInt:&a];
    b = a;
    if (ab.count > 1) [[NSScanner scannerWithString:ab[1]] scanHexInt:&b];
    for (unsigned c = a; c <= b; c++) [out addObject:@(c)];
}

static NSArray<NSString *> *DataLines(const char *path) {
    NSString *txt = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
    if (!txt) {
        fprintf(stderr, "읽지 못함: %s\n", path);
        exit(1);
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [txt componentsSeparatedByString:@"\n"])
        if (l.length > 0 && ![l hasPrefix:@"#"]) [out addObject:l];
    return out;
}

static int RunCases(NSArray *chain, CTFontRef primary) {
    // src/render_test.zig 의 sectionM 과 같은 글자다. 그쪽을 바꾸면 여기도 바꾼다.
    UTF32Char vs16[][2] = {{0x2764, 0xFE0F}, {0x263A, 0xFE0F}, {0x270C, 0xFE0F}, {0x2600, 0xFE0F}, {0x26A0, 0xFE0F},
                           {0x2714, 0xFE0F}, {0x203C, 0xFE0F}, {0x2122, 0xFE0F}, {0x00A9, 0xFE0F}, {0x2197, 0xFE0F}};
    // sectionM 의 `홀로` 줄 — 그 화면의 다른 줄에 없는 글자 (#771 Windows 실기).
    UTF32Char vs16Alone[][2] = {{0x00AE, 0xFE0F}, {0x2665, 0xFE0F}, {0x2660, 0xFE0F},
                                {0x2663, 0xFE0F}, {0x2194, 0xFE0F}, {0x25B6, 0xFE0F}};
    UTF32Char vs15[][2] = {{0x2614, 0xFE0E}, {0x2615, 0xFE0E}, {0x26A1, 0xFE0E}, {0x26BD, 0xFE0E},
                           {0x2648, 0xFE0E}, {0x2764, 0xFE0E}, {0x263A, 0xFE0E}};
    UTF32Char emojiDefault[] = {0x2614, 0x2615, 0x26A1, 0x26BD, 0x2648, 0x1F18E};
    UTF32Char textDefault[] = {0x2764, 0x263A, 0x270C, 0x2600, 0x26A0, 0x2714};
    UTF32Char near1[] = {0x2764, 0xFE0F, 0x1F44B, 0x1F3FB};
    UTF32Char near2[] = {0x2764, 0xFE0F, 0x263A, 0xFE0F};

    printf("=== cluster 하나씩 (resolveGraphemeUncached) ===\n");
    for (size_t i = 0; i < sizeof vs16 / sizeof vs16[0]; i++) DumpLine(primary, @"VS16", Str(vs16[i], 2));
    for (size_t i = 0; i < sizeof vs16Alone / sizeof vs16Alone[0]; i++) DumpLine(primary, @"VS16 홀로", Str(vs16Alone[i], 2));
    for (size_t i = 0; i < sizeof vs15 / sizeof vs15[0]; i++) DumpLine(primary, @"VS15", Str(vs15[i], 2));

    printf("\n=== 묶음 — CTLine 하나 (resolveGraphemeRunInner) ===\n");
    NSMutableString *r16 = [NSMutableString string], *r15 = [NSMutableString string];
    for (size_t i = 0; i < sizeof vs16 / sizeof vs16[0]; i++) [r16 appendString:Str(vs16[i], 2)];
    for (size_t i = 0; i < sizeof vs15 / sizeof vs15[0]; i++) [r15 appendString:Str(vs15[i], 2)];
    DumpLine(primary, @"VS16 연속", r16);
    DumpLine(primary, @"VS15 연속", r15);
    DumpLine(primary, @"이웃 [❤️👋🏻]", Str(near1, 4));
    DumpLine(primary, @"이웃 [❤️☺️]", Str(near2, 4));

    printf("\n=== 단일 글자 — chain 순회 (resolveGlyph) ===\n");
    printf("이모지가 기본 (컬러가 정상)\n");
    for (size_t i = 0; i < sizeof emojiDefault / sizeof emojiDefault[0]; i++) {
        BOOL color;
        NSString *f = SingleFont(chain, primary, emojiDefault[i], &color);
        printf("    %-6X %-28s %s\n", emojiDefault[i], f.UTF8String, color ? "COLOR" : "mono  ✗");
    }
    printf("텍스트가 기본 (흑백이 정상)\n");
    for (size_t i = 0; i < sizeof textDefault / sizeof textDefault[0]; i++) {
        BOOL color;
        NSString *f = SingleFont(chain, primary, textDefault[i], &color);
        printf("    %-6X %-28s %s\n", textDefault[i], f.UTF8String, color ? "COLOR ✗" : "mono");
    }
    return 0;
}

// 설치된 흑백 글꼴 전부 (LastResort 제외). VS15 가 컬러로 간 글자에 흑백 글리프가 정말 없는지
// 가르는 데 쓴다 — 없으면 이모지로 대신 그리는 것이 관례 (ghostty · foot · WezTerm 의 "맞는 글꼴이
// 없으면 조건 없이 다시") 이고, 있는데도 컬러면 CoreText 가 그 글꼴을 고르지 않은 것이다.
static NSArray *InstalledMonoFonts(void) {
    NSArray *names = CFBridgingRelease(CTFontManagerCopyAvailablePostScriptNames());
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n isEqualToString:@"LastResort"]) continue;
        id f = CFBridgingRelease(CTFontCreateWithName((__bridge CFStringRef)n, 15, NULL));
        // 받은 글꼴 이름이 다르면 내려받지 않은 글꼴이다 (CoreText 가 다른 글꼴로 대신 준다).
        if (![PSName((__bridge CTFontRef)f) isEqualToString:n]) continue;
        if (!IsColorFont((__bridge CTFontRef)f)) [out addObject:f];
    }
    return out;
}

static NSArray<NSString *> *MonoFontsWithGlyph(NSArray *fonts, UTF32Char c) {
    unichar u[2];
    CFIndex len = 1;
    u[0] = (unichar)c;
    if (c > 0xFFFF) {
        UTF32Char v = c - 0x10000;
        u[0] = (unichar)(0xD800 + (v >> 10));
        u[1] = (unichar)(0xDC00 + (v & 0x3FF));
        len = 2;
    }
    NSMutableArray *has = [NSMutableArray array];
    for (id f in fonts) {
        CGGlyph g[2] = {0, 0};
        if (CTFontGetGlyphsForCharacters((__bridge CTFontRef)f, u, g, len) && g[0] != 0)
            [has addObject:PSName((__bridge CTFontRef)f)];
    }
    return has;
}

static int RunVS(CTFontRef primary, const char *path) {
    NSMutableArray<NSString *> *seq16 = [NSMutableArray array], *seq15 = [NSMutableArray array];
    NSMutableArray<NSNumber *> *base15 = [NSMutableArray array]; // seq15 와 같은 순서의 base 글자
    for (NSString *l in DataLines(path)) {
        NSString *field = [l componentsSeparatedByString:@";"][0];
        NSArray *parts = [[field stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByString:@" "];
        if (parts.count != 2) continue;
        unsigned base = 0, sel = 0;
        [[NSScanner scannerWithString:parts[0]] scanHexInt:&base];
        [[NSScanner scannerWithString:parts[1]] scanHexInt:&sel];
        UTF32Char cps[2] = {base, sel};
        if (sel == 0xFE0F) [seq16 addObject:Str(cps, 2)];
        if (sel == 0xFE0E) {
            [seq15 addObject:Str(cps, 2)];
            [base15 addObject:@(base)];
        }
    }

    // 묶음 경로 — 40 개씩 이어 붙인 줄. 두 칸짜리 40 개가 120 열 한 줄에 들어가는 정도다.
    // 하나씩 처리한 결과와 글꼴 이름이 다른 cluster 를 센다.
    __block int runDiff = 0;
    void (^checkRuns)(NSArray<NSString *> *) = ^(NSArray<NSString *> *seqs) {
        for (NSUInteger start = 0; start < seqs.count; start += 40) {
            NSUInteger end = MIN(start + 40, seqs.count);
            NSMutableString *line = [NSMutableString string];
            NSMutableArray *offs = [NSMutableArray array];
            for (NSUInteger i = start; i < end; i++) {
                [offs addObject:@(line.length)];
                [line appendString:seqs[i]];
            }
            NSArray *byIdx = FontsByIndex(primary, line);
            for (NSUInteger i = start; i < end; i++) {
                id inRun = byIdx[[offs[i - start] unsignedIntegerValue]];
                id alone = ClusterFont(primary, seqs[i]);
                NSString *a = alone ? PSName((__bridge CTFontRef)alone) : @"(none)";
                NSString *b = inRun != [NSNull null] ? PSName((__bridge CTFontRef)inRun) : @"(none)";
                if (![a isEqualToString:b]) {
                    runDiff++;
                    printf("  묶음과 다름  %-12s 하나씩=%s 묶음=%s\n", Hex(seqs[i]).UTF8String, a.UTF8String, b.UTF8String);
                }
            }
        }
    };

    int bad16 = 0, bad15 = 0;
    NSMutableDictionary<NSString *, NSNumber *> *fonts16 = [NSMutableDictionary dictionary], *fonts15 = [NSMutableDictionary dictionary];
    for (NSString *s in seq16) {
        id f = ClusterFont(primary, s);
        NSString *n = f ? PSName((__bridge CTFontRef)f) : @"(none)";
        fonts16[n] = @(fonts16[n].intValue + 1);
        if (!f || !IsColorFont((__bridge CTFontRef)f)) {
            bad16++;
            printf("  VS16 흑백  %-12s %s\n", Hex(s).UTF8String, n.UTF8String);
        }
    }
    NSArray *monoFonts = nil;
    int noMono = 0;
    for (NSUInteger i = 0; i < seq15.count; i++) {
        NSString *s = seq15[i];
        id f = ClusterFont(primary, s);
        NSString *n = f ? PSName((__bridge CTFontRef)f) : @"(none)";
        fonts15[n] = @(fonts15[n].intValue + 1);
        if (!f || IsColorFont((__bridge CTFontRef)f)) {
            bad15++;
            if (!monoFonts) monoFonts = InstalledMonoFonts();
            NSArray *has = MonoFontsWithGlyph(monoFonts, base15[i].unsignedIntValue);
            if (has.count == 0) noMono++;
            printf("  VS15 컬러  %-12s %-20s 흑백 글리프가 있는 설치 글꼴 %lu 개%s%s\n", Hex(s).UTF8String, n.UTF8String,
                   (unsigned long)has.count, has.count ? " — " : "",
                   [[has subarrayWithRange:NSMakeRange(0, MIN(has.count, 3))] componentsJoinedByString:@", "].UTF8String);
        }
    }
    checkRuns(seq16);
    checkRuns(seq15);

    printf("VS16 %lu 개: 컬러 %lu · 흑백 %d\n", (unsigned long)seq16.count, (unsigned long)(seq16.count - (NSUInteger)bad16), bad16);
    for (NSString *k in [fonts16.allKeys sortedArrayUsingSelector:@selector(compare:)])
        printf("    %-28s %d\n", k.UTF8String, fonts16[k].intValue);
    printf("VS15 %lu 개: 흑백 %lu · 컬러 %d (그중 흑백 글리프가 어느 설치 글꼴에도 없음 %d)\n", (unsigned long)seq15.count,
           (unsigned long)(seq15.count - (NSUInteger)bad15), bad15, noMono);
    for (NSString *k in [fonts15.allKeys sortedArrayUsingSelector:@selector(compare:)])
        printf("    %-28s %d\n", k.UTF8String, fonts15[k].intValue);
    if (monoFonts) printf("    (흑백 글리프는 설치된 흑백 글꼴 %lu 개에서 찾음)\n", (unsigned long)monoFonts.count);
    printf("묶음 경로와 글꼴이 갈린 cluster: %d\n", runDiff);
    return 0;
}

static int RunEP(NSArray *chain, CTFontRef primary, const char *path) {
    NSMutableArray<NSNumber *> *cps = [NSMutableArray array];
    for (NSString *l in DataLines(path)) {
        NSArray *f = [l componentsSeparatedByString:@";"];
        if (f.count < 2) continue;
        NSString *prop = [[f[1] componentsSeparatedByString:@"#"][0]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([prop isEqualToString:@"Emoji_Presentation"]) AddRange(f[0], cps);
    }
    NSMutableDictionary<NSString *, NSNumber *> *byFont = [NSMutableDictionary dictionary];
    NSMutableArray *mono = [NSMutableArray array];
    for (NSNumber *n in cps) {
        BOOL color;
        UTF32Char c = n.unsignedIntValue;
        NSString *f = SingleFont(chain, primary, c, &color);
        byFont[f] = @(byFont[f].intValue + 1);
        if (!color) [mono addObject:[NSString stringWithFormat:@"%X %@ (%@)", c, Str(&c, 1), f]];
    }
    printf("Emoji_Presentation=Yes %lu 개 — 단일 글자 경로가 고른 글꼴\n", (unsigned long)cps.count);
    for (NSString *k in [byFont.allKeys sortedArrayUsingSelector:@selector(compare:)])
        printf("    %-36s %d\n", k.UTF8String, byFont[k].intValue);
    printf("흑백 글꼴로 가는 글자 %lu 개\n", (unsigned long)mono.count);
    for (NSString *m in mono) printf("    %s\n", m.UTF8String);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        kChain = @[ @"Menlo-Regular", @"AppleSDGothicNeo-Regular", @"AppleColorEmoji", @"AppleSymbols" ];
        NSMutableArray *chain = [NSMutableArray array];
        for (NSString *n in kChain) {
            CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)n, 15, NULL);
            // 이름이 없으면 CoreText 가 다른 글꼴을 준다. 그러면 판정이 틀어지니 멈춘다.
            if (![PSName(f) isEqualToString:n]) {
                fprintf(stderr, "chain 글꼴 \"%s\" 을 찾지 못함 (받은 것: %s)\n", n.UTF8String, PSName(f).UTF8String);
                return 1;
            }
            [chain addObject:(__bridge_transfer id)f];
        }
        CTFontRef primary = (__bridge CTFontRef)chain[0];

        if (argc >= 2 && strcmp(argv[1], "cases") == 0) return RunCases(chain, primary);
        if (argc >= 3 && strcmp(argv[1], "vs") == 0) return RunVS(primary, argv[2]);
        if (argc >= 3 && strcmp(argv[1], "ep") == 0) return RunEP(chain, primary, argv[2]);
        fprintf(stderr, "사용법: %s cases | vs <emoji-variation-sequences.txt> | ep <emoji-data.txt>\n", argv[0]);
        return 2;
    }
}
