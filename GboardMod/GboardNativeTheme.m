#import "GboardNativeTheme.h"
#import <objc/runtime.h>

static BOOL IsNumericOrPinyinKey(NSString *text) {
    if (!text || text.length == 0) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed isEqualToString:@"分词"] || [trimmed isEqualToString:@"重输"]) return NO;
    if ([trimmed isEqualToString:@"123"] || [trimmed isEqualToString:@"符"] || [trimmed isEqualToString:@"ABC"]) return NO;
    if ([trimmed isEqualToString:@"确认"] || [trimmed isEqualToString:@"换行"]) return NO;

    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[2-9a-zA-Z\\s]+$" options:0 error:nil];
    });
    return [regex numberOfMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)] > 0;
}

#pragma mark - GKBSoftKeyView Hooks

static void (*orig_softKey_layoutSublayersOfLayer)(id self, SEL _cmd, CALayer *layer) = NULL;
static void my_softKey_layoutSublayersOfLayer(UIView *self, SEL _cmd, CALayer *layer) {
    if (orig_softKey_layoutSublayersOfLayer) {
        orig_softKey_layoutSublayersOfLayer(self, _cmd, layer);
    }

    @try {
        // Find label text to distinguish keycap role
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

        // Apply iOS native keycap geometry and shadow
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
            // Pure White Standard Key (#FFFFFF)
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

        // Clear default background layers so custom styling shines through
        for (UIView *sub in self.subviews) {
            if ([NSStringFromClass([sub class]) containsString:@"ImageViewWithBackground"]) {
                sub.backgroundColor = [UIColor clearColor];
            }
        }
    } @catch (NSException *e) {}
}

static void (*orig_softKey_setIsHighlighted)(id self, SEL _cmd, BOOL highlighted) = NULL;
static void my_softKey_setIsHighlighted(UIView *self, SEL _cmd, BOOL highlighted) {
    if (orig_softKey_setIsHighlighted) {
        orig_softKey_setIsHighlighted(self, _cmd, highlighted);
    }

    @try {
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
            // White key touched -> iOS native touch gray #D2D6DC
            self.backgroundColor = highlighted ? [UIColor colorWithRed:0.82 green:0.84 blue:0.86 alpha:1.0]
                                               : [UIColor whiteColor];
        } else {
            // Gray key touched -> Flash white
            self.backgroundColor = highlighted ? [UIColor whiteColor]
                                               : [UIColor colorWithRed:0.66 green:0.69 blue:0.73 alpha:1.0];
        }
    } @catch (NSException *e) {}
}

#pragma mark - GKBCandidatesCollectionView Hooks

static UICollectionViewCell *(*orig_candidates_cellForItem)(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *ip) = NULL;
static UICollectionViewCell *my_candidates_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *ip) {
    UICollectionViewCell *cell = NULL;
    if (orig_candidates_cellForItem) {
        cell = orig_candidates_cellForItem(self, _cmd, cv, ip);
    }
    if (!cell) return cell;

    @try {
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)v;
                NSString *orig = label.text ?: @"";
                if (orig.length > 0) {
                    // Strip leading numbers like "1.", "2.", "1、", "1 "
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
    } @catch (NSException *e) {}

    return cell;
}

#pragma mark - GKB9KeysSoftKeyboardView Hook

static void (*orig_nineKeys_layoutSubviews)(id self, SEL _cmd) = NULL;
static void my_nineKeys_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_nineKeys_layoutSubviews) {
        orig_nineKeys_layoutSubviews(self, _cmd);
    }
    @try {
        // iOS native keyboard background color: #D0D3DA
        self.backgroundColor = [UIColor colorWithRed:0.816 green:0.827 blue:0.855 alpha:1.0];
    } @catch (NSException *e) {}
}

@implementation GboardNativeTheme

+ (void)installThemeHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. Hook GKBSoftKeyView
        Class softKeyViewCls = objc_getClass("GKBSoftKeyView");
        if (softKeyViewCls) {
            Method mLayout = class_getInstanceMethod(softKeyViewCls, @selector(layoutSublayersOfLayer:));
            if (mLayout) {
                orig_softKey_layoutSublayersOfLayer = (void *)method_getImplementation(mLayout);
                method_setImplementation(mLayout, (IMP)my_softKey_layoutSublayersOfLayer);
            }

            Method mHighlight = class_getInstanceMethod(softKeyViewCls, @selector(setIsHighlighted:));
            if (mHighlight) {
                orig_softKey_setIsHighlighted = (void *)method_getImplementation(mHighlight);
                method_setImplementation(mHighlight, (IMP)my_softKey_setIsHighlighted);
            }
        }

        // 2. Hook GKBCandidatesCollectionView
        Class candidatesViewCls = objc_getClass("GKBCandidatesCollectionView");
        if (candidatesViewCls) {
            Method mCell = class_getInstanceMethod(candidatesViewCls, @selector(collectionView:cellForItemAtIndexPath:));
            if (mCell) {
                orig_candidates_cellForItem = (void *)method_getImplementation(mCell);
                method_setImplementation(mCell, (IMP)my_candidates_cellForItem);
            }
        }

        // 3. Hook GKB9KeysSoftKeyboardView background
        Class nineKeysViewCls = objc_getClass("GKB9KeysSoftKeyboardView");
        if (nineKeysViewCls) {
            Method mNineLayout = class_getInstanceMethod(nineKeysViewCls, @selector(layoutSubviews));
            if (mNineLayout) {
                orig_nineKeys_layoutSubviews = (void *)method_getImplementation(mNineLayout);
                method_setImplementation(mNineLayout, (IMP)my_nineKeys_layoutSubviews);
            } else {
                // If not implemented on subclass, add it pointing to our method
                class_addMethod(nineKeysViewCls, @selector(layoutSubviews), (IMP)my_nineKeys_layoutSubviews, "v@:");
            }
        }
    });
}

@end
