
#include <stdint.h>
#include <sys/types.h>
#include <X11/Xlib.h>

/// Initialize the graphics module.
void gr_init(Display *disp, Visual *vis, Colormap cm);
/// Deinitialize the graphics module.
void gr_deinit();

/// Add an image rectangle to a list if rectangles to draw. This function may
/// actually draw some rectangles, or it may wait till more rectangles are
/// appended. Must be called between `gr_start_drawing` and `gr_finish_drawing`.
/// - `start_col` and `start_row` are zero-based.
/// - `end_col` and `end_row` are exclusive (beyond the last col/row).
/// - `reverse` indicates whether colors should be inverted.
void gr_append_imagerect(Drawable buf, uint32_t image_id, int start_col,
			 int end_col, int start_row, int end_row, int x_pix,
			 int y_pix, int cw, int ch, int reverse);
/// Prepare for image drawing. `cw` and `ch` are dimensions of the cell.
void gr_start_drawing(Drawable buf, int cw, int ch);
/// Finish image drawing. This functions will draw all the rectangles left to
/// draw.
void gr_finish_drawing(Drawable buf);

/// Parse and execute a graphics command. `buf` must start with 'G' and contain
/// at least `len + 1` characters (including '\0'). Returns 0 on success.
/// Additional informations is returned through `graphics_command_result`.
int gr_parse_command(char *buf, size_t len);

/// Executes `command` with the name of the file corresponding to `image_id` as
/// the argument. Executes xmessage with an error message on failure.
void gr_preview_image(uint32_t image_id, const char *command);

/// Checks if we are still really uploading something. Returns 1 if we may be
/// and 0 if we aren't. This is more precise than `graphics_uploading` (and may
/// actually change the value of `graphics_uploading`).
int gr_check_if_still_uploading();

/// Print additional information, draw bounding bounding boxes, etc.
extern char graphics_debug_mode;

/// The (approximate) number of active uploads. If there are active uploads then
/// it is not recommended to do anything computationally heavy.
extern char graphics_uploading;

#define MAX_GRAPHICS_RESPONSE_LEN 256

/// A structure representing the result of a graphics command.
typedef struct {
	/// Indicates if the terminal needs to be redrawn.
	char redraw;
	/// The response of the command that should be sent back to the client
	/// (may be empty if the quiet flag is set).
	char response[MAX_GRAPHICS_RESPONSE_LEN];
	/// Whether there was an error executing this command (not very useful,
	/// the response must be sent back anyway).
	char error;
} GraphicsCommandResult;

/// The result of a graphics command.
extern GraphicsCommandResult graphics_command_result;
