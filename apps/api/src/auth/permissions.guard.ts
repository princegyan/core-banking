import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { SupabaseService } from '../database/supabase.service';
import { PERMISSIONS_KEY } from './permissions.decorator';
import { AuthenticatedRequest } from './auth.guard';

@Injectable()
export class PermissionsGuard
  implements CanActivate
{
  constructor(
    private readonly reflector: Reflector,
    private readonly supabaseService: SupabaseService,
  ) {}

  async canActivate(
    context: ExecutionContext,
  ): Promise<boolean> {
    const requiredPermissions =
      this.reflector.getAllAndOverride<string[]>(
        PERMISSIONS_KEY,
        [
          context.getHandler(),
          context.getClass(),
        ],
      );

    // Endpoint does not require a specific permission.
    if (
      !requiredPermissions ||
      requiredPermissions.length === 0
    ) {
      return true;
    }

    const request =
      context
        .switchToHttp()
        .getRequest<AuthenticatedRequest>();

    const user = request.user;

    if (!user) {
      throw new ForbiddenException(
        'Authenticated user not found',
      );
    }

    const supabase =
      this.supabaseService.getClient();

    const {
      data: userRoles,
      error,
    } = await supabase
      .from('user_roles')
      .select(`
        role_id,
        roles!inner (
          id,
          tenant_id,
          name
        )
      `)
      .eq('user_id', user.id);

    if (error) {
      console.error(
        'Role lookup failed:',
        error.message,
      );

      throw new ForbiddenException(
        'Unable to determine user permissions',
      );
    }

    if (!userRoles || userRoles.length === 0) {
      throw new ForbiddenException(
        'User has no assigned roles',
      );
    }

    const roleIds = userRoles
      .map((item: any) => item.role_id)
      .filter(Boolean);

    const {
      data: rolePermissions,
      error: permissionError,
    } = await supabase
      .from('role_permissions')
      .select(`
        permission_id,
        permissions!inner (
          code
        )
      `)
      .in('role_id', roleIds);

    if (permissionError) {
      console.error(
        'Permission lookup failed:',
        permissionError.message,
      );

      throw new ForbiddenException(
        'Unable to determine user permissions',
      );
    }

    const permissions = new Set(
      (rolePermissions ?? []).map(
        (item: any) =>
          item.permissions.code,
      ),
    );

    const hasAllPermissions =
      requiredPermissions.every(
        (permission) =>
          permissions.has(permission),
      );

    if (!hasAllPermissions) {
      throw new ForbiddenException(
        'You do not have permission to perform this action',
      );
    }

    return true;
  }
}