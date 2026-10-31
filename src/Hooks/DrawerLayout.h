#ifndef NFB_DRAWER_LAYOUT_H
#define NFB_DRAWER_LAYOUT_H

// Geometry for the side menu. Settings and help leave the scrolling list and
// sit at the bottom. D-day sits just above them. Neither moves when the menu
// scrolls. The two custom rows take the slots those items left, under Spaces.

typedef struct {
    float y;
    float h;
    float w;
} NFBBox;

typedef struct {
    float rowY[2];
    float rowH[2];
    float pinY[2];
    float pinH[2];
    float eventsY;
    float eventsH;
    float insetBottom;
    int pinCount;
    int rowCount;
} NFBDrawerPlace;

static int NFBMenuRow(NFBBox box) {
    return box.h >= 40.0f && box.h <= 80.0f && box.w > 200.0f;
}

// The first two menu rows after the gap that follows 프로필/커뮤니티/리스트/스페이스.
// Returns 0 when that pair cannot be seen.
static int NFBFooterIndices(const NFBBox* cells, int count, int* outIndex) {
    int order[64];
    int n = 0;
    if (count > 64) {
        count = 64;
    }
    for (int i = 0; i < count; i++) {
        if (!NFBMenuRow(cells[i])) {
            continue;
        }
        int at = n;
        while (at > 0 && cells[order[at - 1]].y > cells[i].y) {
            order[at] = order[at - 1];
            at--;
        }
        order[at] = i;
        n++;
    }
    if (n < 6) {
        return 0;
    }
    int gapAt = -1;
    for (int i = 4; i < n; i++) {
        float gap = cells[order[i]].y - (cells[order[i - 1]].y + cells[order[i - 1]].h);
        if (gap > 12.0f) {
            gapAt = i;
            break;
        }
    }
    if (gapAt < 0 || gapAt + 1 >= n) {
        return 0;
    }
    outIndex[0] = order[gapAt];
    outIndex[1] = order[gapAt + 1];
    float between = cells[outIndex[1]].y - (cells[outIndex[0]].y + cells[outIndex[0]].h);
    if (between > 24.0f) {
        return 0;
    }
    return 2;
}

static int NFBPlaceDrawer(float viewportH, float offset, float safeBottom, const NFBBox* homes,
                          int pinCount, float eventsH, NFBDrawerPlace* out) {
    if (!out || pinCount != 2 || viewportH < 200.0f) {
        return 0;
    }
    float gap = 14.0f;
    float bottom = offset + viewportH - safeBottom;
    float helpH = homes[1].h;
    float settingsH = homes[0].h;
    float eventsBlock = eventsH > 0.0f ? eventsH + gap : 0.0f;
    float helpY = bottom - helpH;
    float settingsY = helpY - settingsH;
    float eventsY = settingsY - eventsBlock;

    out->pinCount = 2;
    out->pinY[0] = settingsY;
    out->pinH[0] = settingsH;
    out->pinY[1] = helpY;
    out->pinH[1] = helpH;
    out->eventsY = eventsY;
    out->eventsH = eventsH;
    out->rowCount = 2;
    out->rowY[0] = homes[0].y;
    out->rowH[0] = homes[0].h;
    out->rowY[1] = homes[1].y;
    out->rowH[1] = homes[1].h;
    out->insetBottom = (viewportH - (eventsY - offset)) + 8.0f;
    return 1;
}

static int NFBBoxesOverlap(float ay, float ah, float by, float bh) {
    return ay < by + bh - 0.5f && by < ay + ah - 0.5f;
}

#endif
