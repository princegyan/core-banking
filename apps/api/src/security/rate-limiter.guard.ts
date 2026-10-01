import {
  CanActivate,
  ExecutionContext,
  Injectable,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { Request } from 'express';
import { SupabaseService } from '../database/supabase.service';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

@Injectable()
export class RateLimiterGuard implements CanActivate {
  private readonly memoryStore = new Map<string, { count: number; resetAt: number }>();
  private readonly configCache = new Map<string, { maxRequests: number; windowSeconds: number; cachedAt: number }>();

  constructor(private readonly supabase: SupabaseService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<Request>();
    const user = (request as any).user as AuthenticatedUser;

    if (!user) {
      return true; // Limit authenticated users primarily based on tenant
    }

    const key = `${user.id}:${request.path}`;
    const now = Date.now();

    const config = await this.getLimitConfig(user.tenantId, request.path, request.method);

    const record = this.memoryStore.get(key);

    if (!record || record.resetAt <= now) {
      this.memoryStore.set(key, { count: 1, resetAt: now + config.windowSeconds * 1000 });
      return true;
    }

    if (record.count >= config.maxRequests) {
      throw new HttpException('Rate limit exceeded', HttpStatus.TOO_MANY_REQUESTS);
    }

    record.count += 1;
    this.memoryStore.set(key, record);

    return true;
  }

  private async getLimitConfig(tenantId: string, path: string, method: string) {
    const cacheKey = `${tenantId}:${path}:${method}`;
    const cached = this.configCache.get(cacheKey);
    const now = Date.now();

    if (cached && now - cached.cachedAt < 5 * 60 * 1000) {
      return { maxRequests: cached.maxRequests, windowSeconds: cached.windowSeconds };
    }

    const client = this.supabase.getClient();
    const { data } = await client
      .from('api_rate_limits')
      .select('max_requests, window_seconds')
      .eq('tenant_id', tenantId)
      .eq('endpoint_pattern', path)
      .eq('method', method)
      .eq('is_active', true)
      .maybeSingle();

    const result = {
      maxRequests: (data as any)?.max_requests ?? 100,
      windowSeconds: (data as any)?.window_seconds ?? 60,
    };
    
    this.configCache.set(cacheKey, { ...result, cachedAt: now });
    
    return result;
  }
}

