# What fails a release over the frame times of scrolling (FrameTimeGUITests, run by scripts/release.sh). The owner's to
# adjust. Each number of a release is the median of three scrolls of 180 frames; a frame at 120 Hz has 8.3 ms.
#
# Measured on 2026-11-13, a Mac16,5 (M4 Max) on macOS 27.0.1, in the debug build `swift test` makes (as the release runs
# it), five runs of the suite, lowest to highest:
#   list    default  median 5.91-7.12 ms (20% apart)  late 11.1-25.6%  slowest 12.2-18.7 ms
#   icons   default  median 5.12-6.18 ms (20% apart)  late 20.0-26.7%  slowest 15.7-20.6 ms
#   icons   largest  median 3.19-4.09 ms (28% apart)  late  1.7-11.1%  slowest 11.3-15.4 ms
#   compact default  median 7.26-8.03 ms (10% apart)  late 21.7-32.8%  slowest 20.4-24.5 ms
#   compact largest  median 5.01-5.90 ms (17% apart)  late 10.6-13.3%  slowest 17.5-20.6 ms
# The runs spread by up to 28% in a median and 15 points in the late frames: the limits are about twice that.

# Against the last release made on the same Mac model: a median more than this share slower fails, and so does a share
# of late frames (over 8.3 ms) more than this many points above it.
FRAME_MEDIAN_SLOWER_SHARE=0.6
FRAME_LATE_SHARE_RISE=0.3
# Whatever came before, nothing passes these ceilings, about twice the highest measured (8.0 ms and 33% late): several
# releases each a little slower than the last don't add up unseen. With no earlier release from this Mac model, or for a
# view and size the earlier record lacks, they are all that applies.
FRAME_MEDIAN_CEILING_MS=16
FRAME_LATE_SHARE_CEILING=0.65
