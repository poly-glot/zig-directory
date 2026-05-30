/**
 * The single taxonomy root the admin UI scopes against. All admin
 * "list root categories" calls iterate the children of this ID, not the
 * raw root list, so the duplicate Top (id 1) never appears.
 */
export const CANONICAL_ROOT_ID = 3;
