import { Injectable, BadRequestException, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { AddKycDocumentDto } from './dto/add-kyc-document.dto';
import { VerifyDocumentDto } from './dto/verify-document.dto';
import { ClassifyRiskDto } from './dto/classify-risk.dto';

@Injectable()
export class KycService {
  constructor(private readonly supabase: SupabaseService) {}

  async addDocument(tenantId: string, dto: AddKycDocumentDto) {
    const { data, error } = await this.supabase.getClient().rpc('add_kyc_document', {
      p_tenant_id: tenantId,
      p_customer_id: dto.customerId,
      p_document_type: dto.documentType,
      p_document_number: dto.documentNumber || null,
      p_file_path: dto.filePath || null,
      p_file_name: dto.fileName || null,
      p_issue_date: dto.issueDate || null,
      p_expiry_date: dto.expiryDate || null,
      p_issuing_authority: dto.issuingAuthority || null,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (data && data.success === false) {
      throw new BadRequestException(data.error);
    }
    return data;
  }

  async getDocuments(tenantId: string, customerId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('kyc_documents')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('customer_id', customerId);

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async verifyDocument(tenantId: string, documentId: string, verifiedBy: string, dto: VerifyDocumentDto) {
    const { data, error } = await this.supabase.getClient().rpc('verify_kyc_document', {
      p_tenant_id: tenantId,
      p_document_id: documentId,
      p_verified_by: verifiedBy,
      p_approved: dto.approved,
      p_rejection_reason: dto.rejectionReason || null,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (data && data.success === false) {
      throw new BadRequestException(data.error);
    }
    return data;
  }

  async classifyRisk(tenantId: string, classifiedBy: string, dto: ClassifyRiskDto) {
    const { data, error } = await this.supabase.getClient().rpc('classify_customer_risk', {
      p_tenant_id: tenantId,
      p_customer_id: dto.customerId,
      p_risk_level: dto.riskLevel,
      p_risk_score: dto.riskScore || null,
      p_risk_factors: dto.riskFactors || null,
      p_classified_by: classifiedBy,
      p_next_review_date: dto.nextReviewDate || null,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (data && data.success === false) {
      throw new BadRequestException(data.error);
    }
    return data;
  }

  async getRiskClassification(tenantId: string, customerId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('customer_risk_classifications')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('customer_id', customerId)
      .eq('is_current', true)
      .maybeSingle();

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (!data) {
      throw new NotFoundException('Current risk classification not found');
    }
    return data;
  }

  async addRestriction(tenantId: string, imposedBy: string, payload: any) {
    const { data, error } = await this.supabase.getClient().rpc('add_customer_restriction', {
      p_tenant_id: tenantId,
      p_customer_id: payload.customerId,
      p_restriction_type: payload.restrictionType,
      p_reason: payload.reason,
      p_imposed_by: imposedBy,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (data && data.success === false) {
      throw new BadRequestException(data.error);
    }
    return data;
  }

  async liftRestriction(tenantId: string, restrictionId: string, liftedBy: string) {
    const { data, error } = await this.supabase.getClient().rpc('lift_customer_restriction', {
      p_tenant_id: tenantId,
      p_restriction_id: restrictionId,
      p_lifted_by: liftedBy,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (data && data.success === false) {
      throw new BadRequestException(data.error);
    }
    return data;
  }

  async addWatchlist(tenantId: string, addedBy: string, payload: any) {
    const { data, error } = await this.supabase.getClient()
      .from('customer_watchlist')
      .insert({
        tenant_id: tenantId,
        identifier_type: payload.identifierType,
        identifier_value: payload.identifierValue,
        list_source: payload.listSource,
        reason: payload.reason,
        added_by: addedBy,
      })
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async checkWatchlist(tenantId: string, identifierType: string, identifierValue: string) {
    const { data, error } = await this.supabase.getClient().rpc('check_customer_watchlist', {
      p_tenant_id: tenantId,
      p_identifier_type: identifierType,
      p_identifier_value: identifierValue,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async getExpiringDocuments(tenantId: string, daysAhead: number) {
    const { data, error } = await this.supabase.getClient().rpc('get_expiring_documents', {
      p_tenant_id: tenantId,
      p_days_ahead: daysAhead,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async getProfileHistory(tenantId: string, customerId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('customer_profile_history')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }
}
