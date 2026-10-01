import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { Observable, of } from 'rxjs';
import { tap } from 'rxjs/operators';
import { Request, Response } from 'express';
import { SupabaseService } from '../database/supabase.service';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

@Injectable()
export class IdempotencyInterceptor implements NestInterceptor {
  constructor(private readonly supabase: SupabaseService) {}

  async intercept(context: ExecutionContext, next: CallHandler): Promise<Observable<any>> {
    const request = context.switchToHttp().getRequest<Request>();
    const response = context.switchToHttp().getResponse<Response>();
    
    if (!['POST', 'PUT', 'PATCH'].includes(request.method)) {
      return next.handle();
    }

    const idempotencyKey = request.header('x-idempotency-key');
    if (!idempotencyKey) {
      return next.handle();
    }

    const user = (request as any).user as AuthenticatedUser;
    const tenantId = user?.tenantId;

    if (!tenantId) {
      return next.handle();
    }

    const client = this.supabase.getClient();
    
    const { data: existing } = await client
      .from('idempotency_keys')
      .select('status_code, response_body')
      .eq('tenant_id', tenantId)
      .eq('key', idempotencyKey)
      .single();

    if (existing) {
      response.status(existing.status_code);
      return of(existing.response_body);
    }

    return next.handle().pipe(
      tap(async (data) => {
        try {
          await client.from('idempotency_keys').insert({
            key: idempotencyKey,
            tenant_id: tenantId,
            user_id: user.id || null,
            method: request.method,
            path: request.originalUrl || request.path,
            status_code: response.statusCode,
            response_body: data,
          });
        } catch (err) {
          console.error('Failed to save idempotency key:', err);
        }
      })
    );
  }
}
