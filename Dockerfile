# This file is part of Fumoco.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Holger Peters -- see the LICENSE file.

# The built app (npm run build -> dist/), served as static files. Built by
# the release workflow; locally: npm run build && docker build -t fumoco .
FROM nginx:1-alpine
LABEL org.opencontainers.image.source="https://github.com/fundamental-modeling/fumoco" \
      org.opencontainers.image.description="Fumoco, a browser-based editor for FMC diagrams" \
      org.opencontainers.image.licenses="MIT"
COPY dist/ /usr/share/nginx/html/
