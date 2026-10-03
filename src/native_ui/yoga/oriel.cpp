/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// What the tree needs of Yoga beyond its C API: a node's laid-out width set
// after the layout (Tree.leafOnly: a text's new width, without laying the
// tree out again), so what reads the layout back (Tree.replace) sees it.

#include <yoga/Yoga.h>
#include <yoga/node/Node.h>

extern "C" void oriel_yoga_set_layout_width(YGNodeRef node, float width) {
  facebook::yoga::resolveRef(node)->setLayoutDimension(width, facebook::yoga::Dimension::Width);
}
