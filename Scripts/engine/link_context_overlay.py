"""Prove root-widget coordinates before the embedder receives a link menu."""


def apply(source):
    from .overlay import replace_once

    header = source / "content/public/browser/context_menu_params.h"
    replace_once(header, "  bool is_subframe = false;", """  bool is_subframe = false;

  // Browser-only proof; not part of UntrustworthyContextMenuParams or its IPC.
  // False when root hit-test transformation is unavailable.
  bool arx_root_coordinates_valid = false;""")
    implementation = source / "content/browser/renderer_host/render_frame_host_impl.cc"
    replace_once(implementation, "  gfx::PointF transformed_point_f;\n", """  gfx::PointF transformed_point_f;
  // Never inherit renderer metadata as coordinate authority.
  validated_params.arx_root_coordinates_valid = false;
  if (root_view && view == root_view)
    validated_params.arx_root_coordinates_valid = true;
""")
    replace_once(implementation,
                 "    validated_params.y = root_point.y();\n",
                 "    validated_params.y = root_point.y();\n"
                 "    validated_params.arx_root_coordinates_valid = true;\n")
