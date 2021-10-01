@tool
extends MeshInstance3D
class_name LodPatch

##
## A Patch based Terrain system.
##
## @desc:
##     A Patch based terrain system with level of detail support and a very
##     naive seam removal method.
##     [codeblock]
##     As this is GDScript based it is not expected to be performant.
##     Generally this is not very scalable, but it may prove useful for
##     education purposes.
##     [/codeblock]
##

var m = Mutex.new()
var current_key
var mesh_cache := {}
var max_detail := 8
var elevation_function := default_elevation_function

## Compute the subdivision level of this Patch relative to a reference Vector3.
##
## The subdivision levels are always raised to the next power of 2, this
## ensures that when Patches of differing subdivision levels are adjacent to
## each other that their vertices will align where possible.
##
## [codeblock]
## Example:
##     Level 1: x-----------x
##              |           |
##              |           |
##              |           |
##              |           |
##              |           |
##              |           |
##              |           |
##              x-----------x
##
##     Level 2: x-----x-----x
##              |     |     |
##              |     |     |
##              |     |     |
##              x-----x-----x
##              |     |     |
##              |     |     |
##              |     |     |
##              x-----x-----x
##
##     Level 4: x--x--x--x--x
##              |  |  |  |  |
##              x--x--x--x--x
##              |  |  |  |  |
##              x--x--x--x--x
##              |  |  |  |  |
##              x--x--x--x--x
##              |  |  |  |  |
##              x--x--x--x--x
## [/codeblock]
##
func compute_subdivision(reference_point: Vector3, target_point: Vector3) -> int:
    var detail : int = (
        max_detail - (reference_point.snapped(Vector3.ONE * scale).distance_to(
            target_point.snapped(Vector3.ONE * scale)
        ))
    )

    detail = max(1, detail)

    # http://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
    detail -= 1
    detail |= detail >> 1
    detail |= detail >> 2
    detail |= detail >> 4
    detail |= detail >> 8
    detail |= detail >> 16
    detail += 1

    return detail


## Check if the given x and z position is considered unaligned.
##
## An unaligned edge position is one that does not align with a neighbouring
## Patches vertices in the case that the neighbour is of a lower subdivision
## level.
##
## If an unaligned edge vertex's elevation(or y position) is not adjusted,
## it will expose seams / gaps in the resulting Geometry.
##
## Returns a Vector2 identifying the edge direction of this position.
## If this is not an unaligned edge position, returns Vector2.ZERO.
func unaligned_edge_position(x, z, detail) -> Vector2:
    if x == 0:
        if z> 0 and z < detail:
            if z % 2 == 1.0:
                return Vector2.LEFT
    if x == detail:
        if z> 0 and z < detail:
            if z % 2 == 1.0:
                return Vector2.RIGHT

    if z == 0:
        if x > 0 and x < detail:
            if x % 2 == 1.0:
                return Vector2.UP
    if z == detail:
        if x > 0 and x < detail:
            if x % 2 == 1.0:
                return Vector2.DOWN

    return Vector2.ZERO


## Create and assign this Patch's geometry for the given subdivision level.
##
## As a whole the geometry is always for a 1.0 Patch size.
## For each subdivision level step through this size by 1.0 / subdivision level
## so that we get appropriately spaced quads.
##
## Uses the adjusted_elevation function to ensure we avoid gaps and seam in the
## resulting geometry.
## [codeblock]
## TODO: Implement caching of generated patches to improve performance.
## TODO: Implement caching of adjusted edge elevations. This should be
##       independent of generated Patch meshes, as each subdivision level may
##       not have the same neighbour subdivision levels.
## [/codeblock]
func create_patch(detail: int, target: Vector3) -> void:
    detail = clamp(detail, 1, max_detail)

    # We cache meshes based on the requested detail and target position.
    # Unfortunately due to the possibility of variations in neighbour detail
    # levels.
    var key = [detail, target.snapped(Vector3.ONE * scale * 0.5)].hash()

    if key == current_key:
        # Skip this request, we already have this configuration applied
        return

    current_key = key

    if mesh_cache.has(key):
        m.lock()
        call_deferred("set_mesh", mesh_cache[key])
        m.unlock()
    else:
        var patch = SurfaceTool.new()
        patch.begin(Mesh.PRIMITIVE_TRIANGLES)
        var step_size = 1.0 / detail

        for x in range(0.0, detail):
            for z in range(0.0, detail):
                # draw quad
                #  x------x
                #  |00  10|
                #  |      |
                #  |01  11|
                #  x------x
                var verts := []

                # 00
                verts.append(
                    Vector3(
                        x * step_size,
                        adjusted_elevation(
                            x,
                            z,
                            unaligned_edge_position(x, z, detail),
                            step_size,
                            detail,
                            target
                        ),
                        z * step_size
                    )
                )

                # 01
                verts.append(
                    Vector3(
                        x * step_size,
                        adjusted_elevation(
                            x,
                            z + 1,
                            unaligned_edge_position(x, z + 1, detail),
                            step_size,
                            detail,
                            target
                        ),
                        (z + 1) * step_size
                    )
                )

                # 10
                verts.append(
                    Vector3(
                        (x + 1) * step_size,
                        adjusted_elevation(
                            x + 1,
                            z,
                            unaligned_edge_position(x + 1, z, detail),
                            step_size,
                            detail,
                            target
                        ),
                        z * step_size
                    )
                )

                # 11
                verts.append(
                    Vector3(
                        (x + 1) * step_size,
                        adjusted_elevation(
                            x + 1,
                            z + 1,
                            unaligned_edge_position(x + 1, z + 1, detail),
                            step_size,
                            detail,
                            target
                        ),
                        (z + 1) * step_size
                    )
                )

                # Triangle A
                patch.add_vertex(verts[0])
                patch.add_vertex(verts[1])
                patch.add_vertex(verts[2])

                # Triangle B
                patch.add_vertex(verts[3])
                patch.add_vertex(verts[2])
                patch.add_vertex(verts[1])

        # should guard for thread?
        if key != current_key:
            return

        
        m.lock()
        mesh_cache[key] = patch.commit()
        call_deferred("set_mesh", mesh_cache[key])
        m.unlock()

## Gets the elevation value for the given x, z position.
##
## If the given x, z position is considered unaligned then compute the
## neighbouring Patch's subdivision level. If the neighbour's subdivision level
## is less than this Patch's subdivision level adjust the elevation to be
## linearly interpolated from the two adjacent edge positions on this Patch.
##
## Performing this adjustment ensures that non-aligned vertices do not expose
## gaps / seams in  the resulting geometry.
##
## [codeblock]
## Example:
##     Assuming an edge neighbour Patch with a subdivision level of 1, a level 2
##     Patch would need to adjust the following Vertex elevations:
##
##           --------------> Unaligned positions that must be adjusted
##           |          |    linearly between the adjacent elevations(marked N).
##     N-----x-----N    |
##     |     |     |    |
##     |     |     |    |
##     |     |     |    |
##     x-----x-----x <--|
##     |     |     |
##     |     |     |
##     |     |     |
##     x-----x-----x
##
##     Assuming an edge neighbour Patch with a subdivision level of 2, a level 4
##     Patch would need to adjust the following Vertex elevations:
##
##        -----------------> Unaligned positions that must be adjusted
##        |     |       |    linearly between the adjacent elevations(marked N).
##     N--x--N--x--N    |
##     |  |  |  |  |    |
##     x--x--x--x--x <--|
##     |  |  |  |  |    |
##     x--x--x--x--N    |
##     |  |  |  |  |    |
##     x--x--x--x--x <--|
##     |  |  |  |  |
##     x--x--x--x--N
##  [/codeblock]
##
func adjusted_elevation(x, z, unaligned_edge_dir, step_size, detail, target) -> float:
    if detail > 0:
        # x edge
        if unaligned_edge_dir == Vector2.LEFT:
            if compute_subdivision(global_transform.origin + Vector3.LEFT, target) < detail:
                return lerp(
                    elevation_function.call(x * step_size, (z - 1) * step_size),
                    elevation_function.call(x * step_size, (z + 1) * step_size),
                    0.5
                )
        if unaligned_edge_dir == Vector2.RIGHT:
            if compute_subdivision(global_transform.origin + Vector3.RIGHT, target) < detail:
                return lerp(
                    elevation_function.call(x * step_size, (z - 1) * step_size),
                    elevation_function.call(x * step_size, (z + 1) * step_size),
                    0.5
                )

        # z edge
        if unaligned_edge_dir == Vector2.UP:
            if compute_subdivision(global_transform.origin + Vector3.FORWARD, target) < detail:
                return lerp(
                    elevation_function.call((x - 1) * step_size, z * step_size),
                    elevation_function.call((x + 1) * step_size, z * step_size),
                    0.5
                )

        if unaligned_edge_dir == Vector2.DOWN:
            if compute_subdivision(global_transform.origin + Vector3.BACK, target) < detail:
                return lerp(
                    elevation_function.call((x - 1) * step_size, z * step_size),
                    elevation_function.call((x + 1) * step_size, z * step_size),
                    0.5
                )

    return elevation_function.call(x * step_size, z * step_size)


## The default elevation function used to produce geometry. This can be
## overridden by setting the elevation_function to a Callable.
func default_elevation_function(x, z) -> float:
    # NOTE: It is silly to define this OpenSimplexNoise instance here,
    #       however it is expected that this function get user defined and it
    #       keeps the class definition cleaner.
    var simplex = OpenSimplexNoise.new()
    simplex.octaves = 5
    simplex.persistence = 0.4
    simplex.period = 1
    simplex.lacunarity = 1.7
    simplex.seed = 1

    var point = Vector2(
            global_transform.origin.x + x,
            global_transform.origin.z + z
        )

    var y = simplex.get_noise_2dv(point)
    return y


## Perform LOD generation with consideration of the given Target.
func do_lod(target_point: Vector3) -> void:
    var detail = compute_subdivision(global_transform.origin, target_point)
    create_patch(detail, target_point)
