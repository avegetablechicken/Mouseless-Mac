// Synthetic regression fixtures: no live screenshots, permissions or UI needed.
#include "../src/window/capture_native.m"
#include <assert.h>

static CGImageRef fixture(size_t width, size_t height, CGRect content) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL,width,height,8,width*4,space,
        kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context,content);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

int main(void) {
    @autoreleasepool {
        CGImageRef image = fixture(1000,600,CGRectMake(110,170,120,80));
        CGImageRef cropped = trimWindowImage(image);
        assert(CGImageGetWidth(cropped)==124 && CGImageGetHeight(cropped)==84);
        // Cropping must preserve the actual content, including asymmetric placement.
        CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(cropped));
        const UInt8 *pixels = CFDataGetBytePtr(data);
        size_t visible = 0, stride = CGImageGetBytesPerRow(cropped);
        for (size_t y=0;y<84;y++) for (size_t x=0;x<124;x++)
            if (pixels[y*stride+x*4+3]>=32) visible++;
        assert(visible==120*80);
        CFRelease(data);CGImageRelease(cropped);CGImageRelease(image);
        image=fixture(1000,600,CGRectMake(0,0,1000,600));cropped=trimWindowImage(image);
        assert(CGImageGetWidth(cropped)==1000 && CGImageGetHeight(cropped)==600);
        CGImageRelease(cropped);CGImageRelease(image);
        image=fixture(1000,600,CGRectZero);cropped=trimWindowImage(image);
        assert(cropped==NULL);
        CGImageRelease(image);
        puts("PASS Stage Manager alpha crop, asymmetric content, opaque and empty images");
    }
}
