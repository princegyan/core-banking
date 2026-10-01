import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
} from '@nestjs/common';
import { SupabaseService } from '../../database/supabase.service';
import type { AuthenticatedUser } from '../../auth/types/authenticated-user';

@Injectable()
export class SuperAdminGuard implements CanActivate {
  constructor(private readonly supabaseService: SupabaseService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const user = request.user as AuthenticatedUser;

    if (!user || !user.id) {
      throw new ForbiddenException('User authentication required');
    }

    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('platform_super_admins')
      .select('id, is_active')
      .eq('user_id', user.id)
      .eq('is_active', true)
      .maybeSingle();

    if (error || !data) {
      throw new ForbiddenException('Platform SUPER_ADMIN privilege required');
    }

    return true;
  }
}
