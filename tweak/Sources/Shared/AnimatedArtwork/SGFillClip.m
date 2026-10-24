#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <stdint.h>
#import "SGFillClip.h"

// Fill is EeveeImmersive's layered treatment in the 3:4 clip the lock screen fills the screen with:
// the sharp cover edge to edge from the top of the frame, four Gaussian-blurred copies ramping in one
// after another below the fade zone (a progressive blur, only below the artwork, never above it), the
// whole stack dissolving into a dark tint sampled from the cover's bottom edge. A taller phone screen
// cuts such a clip's sides off, so the sharp cover reads full-bleed the way the system's own artwork
// does: crisp edge to edge and cropped, never a centered square floating between blur bars.

// The artwork stays fully crisp above this share of the frame's height, and has fully dissolved into
// the background by this share. Each blur level ramps in over its own band, the lowest bands blurring
// the most. Shares of the frame height, from the top; EeveeImmersive's own tuning.
static const CGFloat kFadeStart = 0.76, kFadeEnd = 0.985;
static const CGFloat kBand[4][2] = {
    {0.74, 0.84}, {0.79, 0.89}, {0.84, 0.94}, {0.89, 0.985}
};
// The blur radii at 640 px across, scaled with the frame. The layers are drawn small and scaled up,
// since they hold no detail, so these read as output pixels.
static const CGFloat kRadius[4] = {2.5, 6.0, 12.0, 22.0};
static const CGFloat kBlurAcross = 192.0;
// A still is one frame held this long; the loop the lock screen plays is this many frames.
static const int32_t kLoopSeconds = 4, kFramesPerSecond = 24;

static CGColorSpaceRef fillColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    return colorSpace;
}

static CIContext *fillCIContext(void) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @YES,
            kCIContextCacheIntermediates: @NO,
        }];
    });
    return context;
}

static CGContextRef bitmapContext(CGSize size) {
    size_t width = (size_t)round(size.width), height = (size_t)round(size.height);
    if (!width || !height) return NULL;
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, fillColorSpace(),
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) CGContextClearRect(context, CGRectMake(0, 0, width, height));
    return context;
}

static UIColor *fillBackgroundColor(CGImageRef cover) {
    size_t width = CGImageGetWidth(cover), height = CGImageGetHeight(cover);
    if (width < 8 || height < 8) return UIColor.blackColor;
    CGRect sampleRect = CGRectMake(floor(width * 0.13), floor(height * 0.92),
                                    floor(width * 0.74), height - floor(height * 0.92));
    CGImageRef sample = CGImageCreateWithImageInRect(cover, sampleRect);
    if (!sample) return UIColor.blackColor;

    enum { kSampleSide = 8 };
    uint8_t pixels[kSampleSide * kSampleSide * 4] = {0};
    CGContextRef context = CGBitmapContextCreate(pixels, kSampleSide, kSampleSide, 8, kSampleSide * 4,
        fillColorSpace(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) {
        CGImageRelease(sample);
        return UIColor.blackColor;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, kSampleSide, kSampleSide), sample);
    CGContextRelease(context);
    CGImageRelease(sample);

    double red = 0, green = 0, blue = 0;
    for (NSUInteger index = 0; index < kSampleSide * kSampleSide; index++) {
        red += pixels[index * 4];
        green += pixels[index * 4 + 1];
        blue += pixels[index * 4 + 2];
    }
    CGFloat r = red / (kSampleSide * kSampleSide * 255.0);
    CGFloat g = green / (kSampleSide * kSampleSide * 255.0);
    CGFloat b = blue / (kSampleSide * kSampleSide * 255.0);
    UIColor *average = [UIColor colorWithRed:r green:g blue:b alpha:1];
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 1;
    if (![average getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) return UIColor.blackColor;
    brightness = MIN(0.42, MAX(0.03, 0.9 * pow(brightness, 1.6)));
    saturation = MIN(saturation * 1.05, 1.0);
    return [UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1];
}

static void drawFilling(CGContextRef context, CGImageRef image, CGRect rect) {
    CGFloat imageWidth = CGImageGetWidth(image), imageHeight = CGImageGetHeight(image);
    if (imageWidth <= 0 || imageHeight <= 0) return;
    CGFloat scale = MAX(rect.size.width / imageWidth, rect.size.height / imageHeight);
    CGSize drawn = CGSizeMake(imageWidth * scale, imageHeight * scale);
    CGRect destination = CGRectMake(rect.origin.x + (rect.size.width - drawn.width) / 2,
                                    rect.origin.y + (rect.size.height - drawn.height) / 2,
                                    drawn.width, drawn.height);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, destination, image);
}

// The cover aspect-filled into `size`, blurred by `baseRadius` (one of kRadius, quoted at 640 px
// across). Blurred small and drawn large: a blur this wide looks the same either way, and on the CPU
// at full size the four levels took seconds per track.
static CGImageRef blurredLayer(CGImageRef cover, CGFloat baseRadius, CGSize size) CF_RETURNS_RETAINED {
    CGFloat across = MIN(kBlurAcross, size.width);
    CGSize small = CGSizeMake(across, MAX(1, round(across * size.height / MAX(size.width, 1))));
    CGFloat sigma = MAX(baseRadius * small.width / 640.0, 0.5);
    CGContextRef context = bitmapContext(small);
    if (!context) return NULL;
    CGContextTranslateCTM(context, 0, small.height);
    CGContextScaleCTM(context, 1, -1);
    drawFilling(context, cover, CGRectMake(0, 0, small.width, small.height));
    CGImageRef unblurred = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!unblurred) return NULL;
    CIImage *input = [CIImage imageWithCGImage:unblurred];
    CGImageRelease(unblurred);
    CIImage *output = [[[input imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:sigma]
        imageByCroppingToRect:input.extent];
    CGImageRef blurred = [fillCIContext() createCGImage:output fromRect:input.extent];
    if (!blurred) return NULL;
    CGContextRef full = bitmapContext(size);
    if (!full) {
        CGImageRelease(blurred);
        return NULL;
    }
    CGContextTranslateCTM(full, 0, size.height);
    CGContextScaleCTM(full, 1, -1);
    CGContextSetInterpolationQuality(full, kCGInterpolationHigh);
    CGContextDrawImage(full, CGRectMake(0, 0, size.width, size.height), blurred);
    CGImageRelease(blurred);
    CGImageRef framed = CGBitmapContextCreateImage(full);
    CGContextRelease(full);
    return framed;
}

// A smoothstep alpha ramp over the whole 0..1 of the gradient it is drawn with: 0 to 1 when rising,
// 1 to 0 otherwise. The stops must span the band the gradient is drawn across exactly; baking the
// band into the stops the way the old edge fade did compresses the ramp into a sliver of it.
static CGGradientRef smoothRamp(BOOL rising) {
    enum { kSteps = 14 };
    CGFloat components[(kSteps + 1) * 4], locations[kSteps + 1];
    for (NSUInteger index = 0; index <= (NSUInteger)kSteps; index++) {
        CGFloat progress = (CGFloat)index / kSteps;
        CGFloat smooth = progress * progress * (3 - 2 * progress);
        locations[index] = progress;
        CGFloat alpha = rising ? smooth : 1 - smooth;
        components[index * 4] = 1;
        components[index * 4 + 1] = 1;
        components[index * 4 + 2] = 1;
        components[index * 4 + 3] = alpha;
    }
    return CGGradientCreateWithColorComponents(fillColorSpace(), components, locations, kSteps + 1);
}

// Fades `context`'s alpha across the band at `top` of `height`, in the flipped (y-down) space the
// art is drawn in: `top` is the band's upper edge on screen.
static void applyBand(CGContextRef context, CGFloat top, CGFloat height, BOOL rising) {
    if (height <= 0) return;
    CGGradientRef gradient = smoothRamp(rising);
    if (!gradient) return;
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeDestinationIn);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, top), CGPointMake(0, top + height), 0);
    CGContextRestoreGState(context);
    CGGradientRelease(gradient);
}

CGImageRef SGFillClipFrame(CGImageRef cover, CGSize size) {
    if (!cover || size.width < 1 || size.height < 1) return NULL;

    // The art stack: the sharp cover filling the frame, the four blurs ramping in below it, then
    // the whole stack fading out toward the bottom.
    CGContextRef art = bitmapContext(size);
    if (!art) return NULL;
    CGContextTranslateCTM(art, 0, size.height);
    CGContextScaleCTM(art, 1, -1);
    drawFilling(art, cover, CGRectMake(0, 0, size.width, size.height));
    for (int level = 0; level < 4; level++) {
        CGImageRef blurred = blurredLayer(cover, kRadius[level], size);
        if (!blurred) continue;
        CGContextRef layer = bitmapContext(size);
        if (!layer) {
            CGImageRelease(blurred);
            continue;
        }
        CGContextTranslateCTM(layer, 0, size.height);
        CGContextScaleCTM(layer, 1, -1);
        CGContextDrawImage(layer, CGRectMake(0, 0, size.width, size.height), blurred);
        CGImageRelease(blurred);
        applyBand(layer, kBand[level][0] * size.height,
                  (kBand[level][1] - kBand[level][0]) * size.height, YES);
        CGImageRef masked = CGBitmapContextCreateImage(layer);
        CGContextRelease(layer);
        if (masked) {
            CGContextDrawImage(art, CGRectMake(0, 0, size.width, size.height), masked);
            CGImageRelease(masked);
        }
    }
    applyBand(art, kFadeStart * size.height, (kFadeEnd - kFadeStart) * size.height, NO);
    CGImageRef stack = CGBitmapContextCreateImage(art);
    CGContextRelease(art);
    if (!stack) return NULL;

    CGContextRef context = bitmapContext(size);
    if (!context) {
        CGImageRelease(stack);
        return NULL;
    }
    CGContextSetFillColorWithColor(context, fillBackgroundColor(cover).CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
    CGContextTranslateCTM(context, 0, size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), stack);
    CGImageRelease(stack);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

BOOL SGFillClipWriteFrame(NSURL *file, CGImageRef frame, CGSize size) {
    if (!file || !frame || size.width < 1 || size.height < 1) return NO;
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    int32_t width = (int32_t)round(size.width), height = (int32_t)round(size.height);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000),
                                           AVVideoMaxKeyFrameIntervalKey: @(kFramesPerSecond)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
        }];
    if (![writer canAddInput:input]) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    BOOL ok = YES;
    int32_t frameCount = kLoopSeconds * kFramesPerSecond;
    for (int32_t index = 0; index < frameCount && ok; index++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) {
            [NSThread sleepForTimeInterval:0.002];
        }
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), (size_t)width, (size_t)height,
            8, CVPixelBufferGetBytesPerRow(buffer), fillColorSpace(),
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        ok = context != NULL;
        if (context) {
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), frame);
            CGContextRelease(context);
        }
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        if (ok) ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(index, kFramesPerSecond)];
        CVPixelBufferRelease(buffer);
    }
    if (!ok) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(kLoopSeconds, 1)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}
