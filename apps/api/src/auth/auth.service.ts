import {
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { AuthenticatedUser } from './types/authenticated-user';

@Injectable()
export class AuthService {
  constructor(
    private readonly supabaseService: SupabaseService,
  ) {}

  /**
   * Authenticate a user with email and password.
   *
   * Returns a Supabase access token that can be used
   * to authenticate subsequent API requests.
   */
  async login(
    email: string,
    password: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const {
      data,
      error,
    } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (error || !data.session || !data.user) {
      console.error(
        'Login failed:',
        error?.message,
      );

      throw new UnauthorizedException(
        error?.message || 'Invalid email or password',
      );
    }

    return {
      accessToken: data.session.access_token,
      refreshToken: data.session.refresh_token,
      expiresAt: data.session.expires_at,
      user: {
        id: data.user.id,
        email: data.user.email,
      },
    };
  }

  /**
   * Validate a Supabase access token and load
   * the corresponding Core Banking user profile.
   */
  async validateToken(
    token: string,
  ): Promise<AuthenticatedUser> {
    const supabase =
      this.supabaseService.getClient();

    // Ask Supabase Auth to validate the token.
    const {
      data: { user: authUser },
      error: authError,
    } = await supabase.auth.getUser(token);

    if (authError || !authUser) {
      console.error(
        'Supabase token validation failed:',
        authError?.message,
      );

      throw new UnauthorizedException(
        'Invalid or expired authentication token',
      );
    }

    // Find the corresponding Core Banking user.
    const {
      data: user,
      error: userError,
    } = await supabase
      .from('users')
      .select(`
        id,
        email,
        tenant_id,
        branch_id,
        is_active
      `)
      .eq('id', authUser.id)
      .maybeSingle();

    if (userError) {
      console.error(
        'User lookup failed:',
        userError.message,
      );

      throw new UnauthorizedException(
        'Unable to load user profile',
      );
    }

    if (!user) {
      throw new UnauthorizedException(
        'User profile not found',
      );
    }

    if (!user.is_active) {
      throw new UnauthorizedException(
        'User account is inactive',
      );
    }

    if (!user.tenant_id) {
      throw new UnauthorizedException(
        'User is not assigned to a tenant',
      );
    }

    return {
      id: user.id,
      email: user.email,
      tenantId: user.tenant_id,
      branchId: user.branch_id,
    };
  }
}
