#import "GboardNativeTheme.h"
#import <objc/runtime.h>

static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL newSel) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (!origMethod || !newMethod) return;
    if (class_addMethod(cls, origSel, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(cls, newSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

static BOOL IsNumericOrPinyinKey(NSString *text) {
    if (!text || text.length == 0) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed isEqualToString:@"分词"] || [trimmed isEqualToString:@"重输"]) return NO;
    if ([trimmed isEqualToString:@"123"] || [trimmed isEqualToString:@"符"] || [trimmed isEqualToString:@"ABC"]) return NO;
    if ([trimmed isEqualToString:@"确认"] || [trimmed isEqualToString:@"换行"]) return NO;

    // Check if contains digits 2-9 or pinyin letters
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[2-9a-zA-Z\\s]+$" options:0 error:nil];
    });
    return [regex numberOfMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)] > 0;
}

@implementation GboardNativeTheme

+ (void)installThemeHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // GKBSoftKeyView layoutSubviews & setIsHighlighted:
        Class softKeyViewCls = objc_getClass("GKBSoftKeyView");
        if (softKeyViewCls) {
            SwizzleInstanceMethod(softKeyViewCls, @selector(layoutSubviews), @selector(lintype_softKey_layoutSubviews));
            SwizzleInstanceMethod(softKeyViewCls, @selector(setIsHighlighted:), @selector(lintype_softKey_setIsHighlighted:));
        }

        // GKBCandidatesCollectionView cellForItemAtIndexPath:
        Class candidatesViewCls = objc_getClass("GKBCandidatesCollectionView");
        if (candidatesViewCls) {
            SwizzleInstanceMethod(candidatesViewCls, @selector(collectionView:cellForItemAtIndexPath:), @selector(lintype_collectionView:cellForItemAtIndexPath:));
        }

        // GKB9KeysSoftKeyboardView & GKBSoftKeyboardView background
        Class nineKeysViewCls = objc_getClass("GKB9KeysSoftKeyboardView");
        if (nineKeysViewCls) {
            SwizzleInstanceMethod(nineKeysViewCls, @selector(layoutSubviews), @selector(lintype_keyboard_layoutSubviews));
        }

        Class softKeyboardViewCls = objc_getClass("GKBSoftKeyboardView");
        if (softKeyboardViewCls) {
            SwizzleInstanceMethod(softKeyboardViewCls, @selector(layoutSubviews), @selector(lintype_keyboard_layoutSubviews));
        }
    });
}

@end

#pragma mark - Hook implementations

@interface UIView (GboardLintypeThemeHooks)
- (void)lintype_softKey_layoutSubviews;
- (void)lintype_softKey_setIsHighlighted:(BOOL)highlighted;
- (void)lintype_keyboard_layoutSubviews;
- (UICollectionViewCell *)lintype_collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation UIView (GboardLintypeThemeHooks)

- (void)lintype_keyboard_layoutSubviews {
    [self lintype_keyboard_layoutSubviews];
    // iOS native keyboard background color: #D0D3DA
    self.backgroundColor = [UIColor colorWithRed:0.816 green:0.827 blue:0.855 alpha:1.0];
}

- (void)lintype_softKey_layoutSubviews {
    [self lintype_softKey_layoutSubviews];

    // Find label text to distinguish key type
    NSString *keyText = @"";
    UILabel *targetLabel = nil;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            targetLabel = (UILabel *)sub;
            keyText = targetLabel.text ?: @"";
            break;
        }
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:[UILabel class]]) {
                targetLabel = (UILabel *)sub2;
                keyText = targetLabel.text ?: @"";
                break;
            }
        }
        if (keyText.length > 0) break;
    }

    NSString *trimmed = [keyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    BOOL isConfirmKey = [trimmed isEqualToString:@"确认"];
    BOOL isMainPinyinKey = IsNumericOrPinyinKey(trimmed);

    // Apply iOS native keycap styling
    self.layer.cornerRadius = 7.5;
    self.layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:1.0].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 1.2);
    self.layer.shadowRadius = 0.4;
    self.layer.masksToBounds = NO;

    if (isConfirmKey) {
        // iOS Blue Confirm Key
        self.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        self.layer.shadowOpacity = 0.28;
        if (targetLabel) {
            targetLabel.textColor = [UIColor whiteColor];
            targetLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        }
    } else if (isMainPinyinKey) {
        // Pure White Standard Key
        self.backgroundColor = [UIColor whiteColor];
        self.layer.shadowOpacity = 0.28;
        if (targetLabel) {
            targetLabel.textColor = [UIColor blackColor];
        }
    } else {
        // Functional / Side Key (#A9AFBB)
        self.backgroundColor = [UIColor colorWithRed:0.66 green:0.69 blue:0.73 alpha:1.0];
        self.layer.shadowOpacity = 0.22;
        if (targetLabel) {
            targetLabel.textColor = [UIColor blackColor];
            targetLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        }
    }

    // Set subviews to clear background so our keycap background is visible
    for (UIView *sub in self.subviews) {
        if ([NSStringFromClass([sub class]) containsString:@"ImageViewWithBackground"]) {
            sub.backgroundColor = [UIColor clearColor];
        }
    }
}

- (void)lintype_softKey_setIsHighlighted:(BOOL)highlighted {
    [self lintype_softKey_setIsHighlighted:highlighted];

    NSString *keyText = @"";
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            keyText = ((UILabel *)sub).text ?: @"";
            break;
        }
    }
    NSString *trimmed = [keyText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([trimmed isEqualToString:@"确认"]) {
        self.backgroundColor = highlighted ? [UIColor colorWithRed:0.0 green:0.35 blue:0.8 alpha:1.0]
                                           : [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    } else if (IsNumericOrPinyinKey(trimmed)) {
        // White key pressed -> iOS native touch gray #D2D6DC
        self.backgroundColor = highlighted ? [UIColor colorWithRed:0.82 green:0.84 blue:0.86 alpha:1.0]
                                           : [UIColor whiteColor];
    } else {
        // Gray functional key pressed -> White flash
        self.backgroundColor = highlighted ? [UIColor whiteColor]
                                           : [UIColor colorWithRed:0.66 green:0.69 blue:0.73 alpha:1.0];
    }
}

- (UICollectionViewCell *)lintype_collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [self lintype_collectionView:collectionView cellForItemAtIndexPath:indexPath];
    if (!cell) return cell;

    // Remove any leading numbers from candidate text and apply iOS native font
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)v;
            NSString *orig = label.text ?: @"";
            if (orig.length > 0) {
                // Strip leading index like "1.", "2.", "1、", "1 " etc.
                NSRegularExpression *digitPrefix = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+[\\.\\、\\s]+" options:0 error:nil];
                NSString *cleaned = [digitPrefix stringByReplacingMatchesInString:orig options:0 range:NSMakeRange(0, orig.length) withTemplate:@""];
                if (![cleaned isEqualToString:orig]) {
                    label.text = cleaned;
                }
            }
            label.textColor = [UIColor blackColor];
            label.font = [UIFont systemFontOfSize:19.5 weight:UIFontWeightRegular];
        }
    }
    cell.backgroundColor = [UIColor clearColor];
    return cell;
}

@end
